"""Compute Optimizer rightsizing report generator.

Pulls rightsizing recommendations from AWS Compute Optimizer across the
supported resource families (EC2 instances, Auto Scaling groups, EBS volumes,
and Lambda functions), estimates the achievable monthly savings, writes a
structured JSON report plus a human-readable summary to S3, and publishes the
headline numbers to an SNS topic.

The function is read-only against the account: it never resizes or deletes a
resource. It surfaces recommendations for a human to act on.

Environment variables
----------------------
REPORT_BUCKET      (required) S3 bucket the report is written to.
REPORT_PREFIX      (optional) Key prefix for reports. Default "rightsizing/".
SNS_TOPIC_ARN      (optional) Topic the summary is published to. Empty = skip.
SAVINGS_THRESHOLD  (optional) Minimum estimated monthly USD savings for a
                              recommendation to be listed. Default "1".
RECOMMENDATION_RANK(optional) Compute Optimizer preference rank to report on:
                              1 = most conservative, 3 = most aggressive.
                              Default "1".
LOG_LEVEL          (optional) Python log level name. Default "INFO".
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
from typing import Any, Callable, Iterable

import boto3

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

# Compute Optimizer exposes a recommendation "rank" (1-3). Rank 1 is the most
# conservative sizing; higher ranks trade more headroom for more savings.
_DEFAULT_RANK = 1


def _client(service: str) -> Any:
    """Return a boto3 client. Wrapped so tests can monkeypatch a factory."""
    return boto3.client(service)


def _monthly_savings(entry: dict[str, Any]) -> float:
    """Extract the estimated monthly savings value from a recommendation option.

    Compute Optimizer nests the figure under
    savingsOpportunity.estimatedMonthlySavings.value. Missing data is treated
    as zero savings rather than raising.
    """
    opportunity = entry.get("savingsOpportunity") or {}
    estimate = opportunity.get("estimatedMonthlySavings") or {}
    try:
        return float(estimate.get("value", 0.0) or 0.0)
    except (TypeError, ValueError):
        return 0.0


def _paginate(
    fetch: Callable[..., dict[str, Any]],
    items_key: str,
) -> Iterable[dict[str, Any]]:
    """Yield every item across a Compute Optimizer paginated response.

    The Compute Optimizer Get* APIs use a `nextToken` cursor rather than a
    standard boto3 paginator, so the loop is explicit.
    """
    next_token: str | None = None
    while True:
        kwargs: dict[str, Any] = {"maxResults": 100}
        if next_token:
            kwargs["nextToken"] = next_token
        response = fetch(**kwargs)
        for item in response.get(items_key, []):
            yield item
        next_token = response.get("nextToken")
        if not next_token:
            return


def _pick_option(
    options: list[dict[str, Any]],
    rank: int,
) -> dict[str, Any] | None:
    """Select the recommendation option matching the requested rank.

    Falls back to the option with the greatest estimated savings when no option
    carries the requested rank.
    """
    if not options:
        return None
    for option in options:
        if int(option.get("rank", 0)) == rank:
            return option
    return max(options, key=_monthly_savings)


def _collect_ec2(rank: int) -> list[dict[str, Any]]:
    client = _client("compute-optimizer")
    findings: list[dict[str, Any]] = []
    for rec in _paginate(
        client.get_ec2_instance_recommendations,
        "instanceRecommendations",
    ):
        if rec.get("finding") != "Overprovisioned":
            # Only overprovisioned instances have a downsizing opportunity.
            continue
        option = _pick_option(rec.get("recommendationOptions", []), rank)
        if option is None:
            continue
        findings.append(
            {
                "resource_type": "EC2Instance",
                "resource_arn": rec.get("instanceArn", ""),
                "resource_name": rec.get("instanceName", ""),
                "current": rec.get("currentInstanceType", ""),
                "recommended": option.get("instanceType", ""),
                "estimated_monthly_savings": round(_monthly_savings(option), 2),
            }
        )
    return findings


def _collect_asg(rank: int) -> list[dict[str, Any]]:
    client = _client("compute-optimizer")
    findings: list[dict[str, Any]] = []
    for rec in _paginate(
        client.get_auto_scaling_group_recommendations,
        "autoScalingGroupRecommendations",
    ):
        if rec.get("finding") != "Overprovisioned":
            continue
        option = _pick_option(rec.get("recommendationOptions", []), rank)
        if option is None:
            continue
        config = option.get("configuration") or {}
        current = rec.get("currentConfiguration") or {}
        findings.append(
            {
                "resource_type": "AutoScalingGroup",
                "resource_arn": rec.get("autoScalingGroupArn", ""),
                "resource_name": rec.get("autoScalingGroupName", ""),
                "current": current.get("instanceType", ""),
                "recommended": config.get("instanceType", ""),
                "estimated_monthly_savings": round(_monthly_savings(option), 2),
            }
        )
    return findings


def _collect_ebs(rank: int) -> list[dict[str, Any]]:
    client = _client("compute-optimizer")
    findings: list[dict[str, Any]] = []
    for rec in _paginate(
        client.get_ebs_volume_recommendations,
        "volumeRecommendations",
    ):
        if rec.get("finding") != "NotOptimized":
            continue
        option = _pick_option(rec.get("volumeRecommendationOptions", []), rank)
        if option is None:
            continue
        config = option.get("configuration") or {}
        current = rec.get("currentConfiguration") or {}
        findings.append(
            {
                "resource_type": "EBSVolume",
                "resource_arn": rec.get("volumeArn", ""),
                "resource_name": rec.get("volumeArn", "").split("/")[-1],
                "current": current.get("volumeType", ""),
                "recommended": config.get("volumeType", ""),
                "estimated_monthly_savings": round(_monthly_savings(option), 2),
            }
        )
    return findings


def _collect_lambda(rank: int) -> list[dict[str, Any]]:
    client = _client("compute-optimizer")
    findings: list[dict[str, Any]] = []
    for rec in _paginate(
        client.get_lambda_function_recommendations,
        "lambdaFunctionRecommendations",
    ):
        if rec.get("finding") != "NotOptimized":
            continue
        option = _pick_option(
            rec.get("memorySizeRecommendationOptions", []), rank
        )
        if option is None:
            continue
        findings.append(
            {
                "resource_type": "LambdaFunction",
                "resource_arn": rec.get("functionArn", ""),
                "resource_name": rec.get("functionArn", "").split(":")[-1],
                "current": f"{rec.get('currentMemorySize', 0)}MB",
                "recommended": f"{option.get('memorySize', 0)}MB",
                "estimated_monthly_savings": round(_monthly_savings(option), 2),
            }
        )
    return findings


_COLLECTORS: dict[str, Callable[[int], list[dict[str, Any]]]] = {
    "EC2Instance": _collect_ec2,
    "AutoScalingGroup": _collect_asg,
    "EBSVolume": _collect_ebs,
    "LambdaFunction": _collect_lambda,
}


def _build_report(rank: int, threshold: float) -> dict[str, Any]:
    """Gather recommendations across every resource family into one report."""
    findings: list[dict[str, Any]] = []
    per_type: dict[str, dict[str, Any]] = {}

    for resource_type, collector in _COLLECTORS.items():
        try:
            collected = collector(rank)
        except Exception:  # noqa: BLE001 - one family failing must not sink the run
            logger.exception("Failed to collect %s recommendations", resource_type)
            collected = []

        kept = [
            item
            for item in collected
            if item["estimated_monthly_savings"] >= threshold
        ]
        kept.sort(key=lambda i: i["estimated_monthly_savings"], reverse=True)
        findings.extend(kept)
        per_type[resource_type] = {
            "count": len(kept),
            "estimated_monthly_savings": round(
                sum(i["estimated_monthly_savings"] for i in kept), 2
            ),
        }

    total_savings = round(
        sum(i["estimated_monthly_savings"] for i in findings), 2
    )
    generated_at = dt.datetime.now(dt.timezone.utc).isoformat()

    return {
        "generated_at": generated_at,
        "recommendation_rank": rank,
        "savings_threshold": threshold,
        "total_estimated_monthly_savings": total_savings,
        "resource_count": len(findings),
        "by_resource_type": per_type,
        "recommendations": findings,
    }


def _format_summary(report: dict[str, Any]) -> str:
    """Render a short plain-text summary suitable for an SNS notification."""
    lines = [
        "Rightsizing report",
        f"Generated: {report['generated_at']}",
        f"Recommendations: {report['resource_count']}",
        f"Estimated monthly savings: ${report['total_estimated_monthly_savings']:.2f}",
        "",
        "By resource type:",
    ]
    for resource_type, stats in report["by_resource_type"].items():
        lines.append(
            f"  {resource_type}: {stats['count']} "
            f"(${stats['estimated_monthly_savings']:.2f}/mo)"
        )
    return "\n".join(lines)


def _write_report(bucket: str, prefix: str, report: dict[str, Any]) -> str:
    """Persist the JSON report to S3 under a date-partitioned key."""
    now = dt.datetime.now(dt.timezone.utc)
    key = (
        f"{prefix.rstrip('/')}/"
        f"year={now:%Y}/month={now:%m}/day={now:%d}/"
        f"rightsizing-{now:%Y%m%dT%H%M%SZ}.json"
    )
    _client("s3").put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps(report, indent=2).encode("utf-8"),
        ContentType="application/json",
        ServerSideEncryption="aws:kms",
    )
    logger.info("Wrote rightsizing report to s3://%s/%s", bucket, key)
    return key


def _publish_summary(topic_arn: str, report: dict[str, Any]) -> None:
    _client("sns").publish(
        TopicArn=topic_arn,
        Subject="AWS rightsizing recommendations",
        Message=_format_summary(report),
    )
    logger.info("Published rightsizing summary to %s", topic_arn)


def handler(event: dict[str, Any] | None, context: Any = None) -> dict[str, Any]:
    """Lambda entry point. Returns the report metadata."""
    bucket = os.environ["REPORT_BUCKET"]
    prefix = os.environ.get("REPORT_PREFIX", "rightsizing/")
    topic_arn = os.environ.get("SNS_TOPIC_ARN", "").strip()

    try:
        threshold = float(os.environ.get("SAVINGS_THRESHOLD", "1"))
    except ValueError:
        threshold = 1.0
    try:
        rank = int(os.environ.get("RECOMMENDATION_RANK", str(_DEFAULT_RANK)))
    except ValueError:
        rank = _DEFAULT_RANK
    rank = min(max(rank, 1), 3)

    report = _build_report(rank, threshold)
    key = _write_report(bucket, prefix, report)

    if topic_arn:
        _publish_summary(topic_arn, report)

    return {
        "report_key": key,
        "resource_count": report["resource_count"],
        "total_estimated_monthly_savings": report[
            "total_estimated_monthly_savings"
        ],
    }
