"""Idle-resource finder.

Scans an account for resources that commonly accrue cost while sitting idle and
compiles them into a report a human can act on:

* Unattached EBS volumes (state "available").
* Elastic IPs that are not associated with an instance or network interface.
* EBS snapshots older than a configurable age (optionally only those whose
  source volume no longer exists).

The function is strictly read-only: it only issues describe/get calls and never
deletes or detaches a resource. Any resource carrying one of the configured
exclusion tag keys is skipped so that intentionally-retained resources are left
alone. Findings are written as a JSON report to S3 and a short summary is
published to an SNS topic.

Cost figures are approximate. They multiply the resource size by a documented,
per-Region-agnostic blended rate; they are meant for prioritisation, not
billing reconciliation.

Environment variables
----------------------
REPORT_BUCKET           (required) S3 bucket the report is written to.
REPORT_PREFIX           (optional) Key prefix. Default "idle-resources/".
SNS_TOPIC_ARN           (optional) Topic the summary is published to. Empty = skip.
STALE_SNAPSHOT_AGE_DAYS (optional) Minimum snapshot age, in days, to flag.
                                   Default "90".
ORPHANED_SNAPSHOTS_ONLY (optional) "true" to flag only snapshots whose source
                                   volume no longer exists. Default "false".
EXCLUSION_TAG_KEYS      (optional) Comma-separated tag keys that exempt a
                                   resource from the report. Default
                                   "finops:keep".
EBS_GB_MONTH_USD        (optional) Blended per-GB-month price for EBS volumes.
                                   Default "0.08".
SNAPSHOT_GB_MONTH_USD   (optional) Per-GB-month price for EBS snapshots.
                                   Default "0.05".
EIP_MONTH_USD           (optional) Monthly price of an idle Elastic IP.
                                   Default "3.60".
LOG_LEVEL               (optional) Python log level name. Default "INFO".
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
from typing import Any, Iterable

import boto3

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

# Documented default blended prices (USD). Overridable via environment so the
# report can be tuned to a Region or negotiated rate without a code change.
_DEFAULT_EBS_GB_MONTH = 0.08
_DEFAULT_SNAPSHOT_GB_MONTH = 0.05
_DEFAULT_EIP_MONTH = 3.60
_DEFAULT_STALE_SNAPSHOT_AGE_DAYS = 90
_DEFAULT_EXCLUSION_TAG_KEYS = "finops:keep"


def _client(service: str) -> Any:
    """Return a boto3 client. Wrapped so tests can monkeypatch a factory."""
    return boto3.client(service)


def _tags_to_dict(tags: Iterable[dict[str, str]] | None) -> dict[str, str]:
    """Normalise an EC2 [{Key, Value}] tag list into a plain dict."""
    return {t["Key"]: t.get("Value", "") for t in (tags or [])}


def _is_excluded(tags: dict[str, str], exclusion_keys: set[str]) -> bool:
    """Return True when any exclusion tag key is present on the resource."""
    return any(key in tags for key in exclusion_keys)


def _name_from_tags(tags: dict[str, str]) -> str:
    return tags.get("Name", "")


def _float_env(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, str(default)))
    except (TypeError, ValueError):
        return default


def _find_unattached_volumes(
    exclusion_keys: set[str],
    ebs_gb_month: float,
) -> list[dict[str, Any]]:
    """Volumes in the 'available' state are not attached to any instance."""
    client = _client("ec2")
    findings: list[dict[str, Any]] = []
    paginator = client.get_paginator("describe_volumes")
    for page in paginator.paginate(
        Filters=[{"Name": "status", "Values": ["available"]}]
    ):
        for volume in page.get("Volumes", []):
            tags = _tags_to_dict(volume.get("Tags"))
            if _is_excluded(tags, exclusion_keys):
                continue
            size_gb = int(volume.get("Size", 0))
            findings.append(
                {
                    "resource_type": "EBSVolume",
                    "resource_id": volume.get("VolumeId", ""),
                    "resource_name": _name_from_tags(tags),
                    "detail": {
                        "size_gb": size_gb,
                        "volume_type": volume.get("VolumeType", ""),
                        "availability_zone": volume.get("AvailabilityZone", ""),
                        "created": _isoformat(volume.get("CreateTime")),
                    },
                    "estimated_monthly_cost": round(size_gb * ebs_gb_month, 2),
                }
            )
    return findings


def _find_idle_addresses(
    exclusion_keys: set[str],
    eip_month: float,
) -> list[dict[str, Any]]:
    """Elastic IPs without an AssociationId are billed but unused."""
    client = _client("ec2")
    findings: list[dict[str, Any]] = []
    response = client.describe_addresses()
    for address in response.get("Addresses", []):
        if address.get("AssociationId"):
            continue
        tags = _tags_to_dict(address.get("Tags"))
        if _is_excluded(tags, exclusion_keys):
            continue
        findings.append(
            {
                "resource_type": "ElasticIP",
                "resource_id": address.get("AllocationId", ""),
                "resource_name": _name_from_tags(tags),
                "detail": {
                    "public_ip": address.get("PublicIp", ""),
                    "domain": address.get("Domain", ""),
                },
                "estimated_monthly_cost": round(eip_month, 2),
            }
        )
    return findings


def _existing_volume_ids() -> set[str]:
    """Return the set of volume IDs that currently exist in the account."""
    client = _client("ec2")
    ids: set[str] = set()
    paginator = client.get_paginator("describe_volumes")
    for page in paginator.paginate():
        for volume in page.get("Volumes", []):
            vol_id = volume.get("VolumeId")
            if vol_id:
                ids.add(vol_id)
    return ids


def _find_stale_snapshots(
    exclusion_keys: set[str],
    snapshot_gb_month: float,
    age_days: int,
    orphaned_only: bool,
) -> list[dict[str, Any]]:
    """Self-owned snapshots older than age_days (optionally orphaned only)."""
    client = _client("ec2")
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=age_days)
    live_volumes = _existing_volume_ids() if orphaned_only else set()

    findings: list[dict[str, Any]] = []
    paginator = client.get_paginator("describe_snapshots")
    for page in paginator.paginate(OwnerIds=["self"]):
        for snapshot in page.get("Snapshots", []):
            start = snapshot.get("StartTime")
            if start is None or start > cutoff:
                continue

            source_volume = snapshot.get("VolumeId", "")
            orphaned = source_volume not in live_volumes
            if orphaned_only and not orphaned:
                continue

            tags = _tags_to_dict(snapshot.get("Tags"))
            if _is_excluded(tags, exclusion_keys):
                continue

            size_gb = int(snapshot.get("VolumeSize", 0))
            findings.append(
                {
                    "resource_type": "EBSSnapshot",
                    "resource_id": snapshot.get("SnapshotId", ""),
                    "resource_name": _name_from_tags(tags),
                    "detail": {
                        "size_gb": size_gb,
                        "source_volume_id": source_volume,
                        "source_volume_exists": (
                            None if not orphaned_only else not orphaned
                        ),
                        "age_days": _age_days(start),
                        "started": _isoformat(start),
                    },
                    "estimated_monthly_cost": round(
                        size_gb * snapshot_gb_month, 2
                    ),
                }
            )
    return findings


def _isoformat(value: Any) -> str:
    """Render a datetime (or None) as an ISO 8601 string."""
    if isinstance(value, dt.datetime):
        return value.astimezone(dt.timezone.utc).isoformat()
    return ""


def _age_days(start: dt.datetime) -> int:
    delta = dt.datetime.now(dt.timezone.utc) - start.astimezone(dt.timezone.utc)
    return max(delta.days, 0)


def _build_report(
    exclusion_keys: set[str],
    age_days: int,
    orphaned_only: bool,
    rates: dict[str, float],
) -> dict[str, Any]:
    """Gather idle resources across every category into one report."""
    categories = {
        "EBSVolume": lambda: _find_unattached_volumes(
            exclusion_keys, rates["ebs_gb_month"]
        ),
        "ElasticIP": lambda: _find_idle_addresses(
            exclusion_keys, rates["eip_month"]
        ),
        "EBSSnapshot": lambda: _find_stale_snapshots(
            exclusion_keys, rates["snapshot_gb_month"], age_days, orphaned_only
        ),
    }

    findings: list[dict[str, Any]] = []
    per_type: dict[str, dict[str, Any]] = {}

    for resource_type, collector in categories.items():
        try:
            collected = collector()
        except Exception:  # noqa: BLE001 - one category must not sink the run
            logger.exception("Failed to scan %s resources", resource_type)
            collected = []

        collected.sort(
            key=lambda i: i["estimated_monthly_cost"], reverse=True
        )
        findings.extend(collected)
        per_type[resource_type] = {
            "count": len(collected),
            "estimated_monthly_cost": round(
                sum(i["estimated_monthly_cost"] for i in collected), 2
            ),
        }

    total_cost = round(
        sum(i["estimated_monthly_cost"] for i in findings), 2
    )

    return {
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "stale_snapshot_age_days": age_days,
        "orphaned_snapshots_only": orphaned_only,
        "exclusion_tag_keys": sorted(exclusion_keys),
        "total_estimated_monthly_cost": total_cost,
        "resource_count": len(findings),
        "by_resource_type": per_type,
        "idle_resources": findings,
    }


def _format_summary(report: dict[str, Any]) -> str:
    """Render a short plain-text summary suitable for an SNS notification."""
    lines = [
        "Idle-resource report",
        f"Generated: {report['generated_at']}",
        f"Idle resources: {report['resource_count']}",
        (
            "Estimated monthly cost: "
            f"${report['total_estimated_monthly_cost']:.2f}"
        ),
        "",
        "By resource type:",
    ]
    for resource_type, stats in report["by_resource_type"].items():
        lines.append(
            f"  {resource_type}: {stats['count']} "
            f"(${stats['estimated_monthly_cost']:.2f}/mo)"
        )
    lines.append("")
    lines.append(
        "Resources are reported only. Review before deleting; tag with an "
        "exclusion key to suppress."
    )
    return "\n".join(lines)


def _write_report(bucket: str, prefix: str, report: dict[str, Any]) -> str:
    """Persist the JSON report to S3 under a date-partitioned key."""
    now = dt.datetime.now(dt.timezone.utc)
    key = (
        f"{prefix.rstrip('/')}/"
        f"year={now:%Y}/month={now:%m}/day={now:%d}/"
        f"idle-resources-{now:%Y%m%dT%H%M%SZ}.json"
    )
    _client("s3").put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps(report, indent=2).encode("utf-8"),
        ContentType="application/json",
        ServerSideEncryption="aws:kms",
    )
    logger.info("Wrote idle-resource report to s3://%s/%s", bucket, key)
    return key


def _publish_summary(topic_arn: str, report: dict[str, Any]) -> None:
    _client("sns").publish(
        TopicArn=topic_arn,
        Subject="AWS idle-resource report",
        Message=_format_summary(report),
    )
    logger.info("Published idle-resource summary to %s", topic_arn)


def _parse_exclusion_keys(raw: str) -> set[str]:
    return {key.strip() for key in raw.split(",") if key.strip()}


def handler(event: dict[str, Any] | None, context: Any = None) -> dict[str, Any]:
    """Lambda entry point. Returns the report metadata."""
    bucket = os.environ["REPORT_BUCKET"]
    prefix = os.environ.get("REPORT_PREFIX", "idle-resources/")
    topic_arn = os.environ.get("SNS_TOPIC_ARN", "").strip()

    try:
        age_days = int(
            os.environ.get(
                "STALE_SNAPSHOT_AGE_DAYS", str(_DEFAULT_STALE_SNAPSHOT_AGE_DAYS)
            )
        )
    except ValueError:
        age_days = _DEFAULT_STALE_SNAPSHOT_AGE_DAYS
    age_days = max(age_days, 0)

    orphaned_only = (
        os.environ.get("ORPHANED_SNAPSHOTS_ONLY", "false").strip().lower()
        == "true"
    )
    exclusion_keys = _parse_exclusion_keys(
        os.environ.get("EXCLUSION_TAG_KEYS", _DEFAULT_EXCLUSION_TAG_KEYS)
    )

    rates = {
        "ebs_gb_month": _float_env("EBS_GB_MONTH_USD", _DEFAULT_EBS_GB_MONTH),
        "snapshot_gb_month": _float_env(
            "SNAPSHOT_GB_MONTH_USD", _DEFAULT_SNAPSHOT_GB_MONTH
        ),
        "eip_month": _float_env("EIP_MONTH_USD", _DEFAULT_EIP_MONTH),
    }

    report = _build_report(exclusion_keys, age_days, orphaned_only, rates)
    key = _write_report(bucket, prefix, report)

    if topic_arn:
        _publish_summary(topic_arn, report)

    return {
        "report_key": key,
        "resource_count": report["resource_count"],
        "total_estimated_monthly_cost": report[
            "total_estimated_monthly_cost"
        ],
    }
