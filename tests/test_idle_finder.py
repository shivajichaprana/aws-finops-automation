"""Unit tests for the idle-resource finder handler."""

from __future__ import annotations

import datetime as dt
import json
from typing import Any

import pytest

from fakes import FakeEC2, RecordingS3, RecordingSNS, make_client_factory


def _tags(**kwargs: str) -> list[dict[str, str]]:
    return [{"Key": k, "Value": v} for k, v in kwargs.items()]


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


# --- pure helpers ---------------------------------------------------------


def test_tags_to_dict(idle_finder: Any) -> None:
    result = idle_finder._tags_to_dict(_tags(Name="db", Env="prod"))
    assert result == {"Name": "db", "Env": "prod"}
    assert idle_finder._tags_to_dict(None) == {}


def test_is_excluded(idle_finder: Any) -> None:
    keys = {"finops:keep"}
    assert idle_finder._is_excluded({"finops:keep": "true"}, keys) is True
    assert idle_finder._is_excluded({"Name": "x"}, keys) is False


def test_parse_exclusion_keys(idle_finder: Any) -> None:
    assert idle_finder._parse_exclusion_keys("a, b ,,c") == {"a", "b", "c"}
    assert idle_finder._parse_exclusion_keys("") == set()


def test_float_env_falls_back_on_bad_value(
    idle_finder: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("EBS_GB_MONTH_USD", "not-a-number")
    assert idle_finder._float_env("EBS_GB_MONTH_USD", 0.08) == 0.08
    monkeypatch.setenv("EBS_GB_MONTH_USD", "0.10")
    assert idle_finder._float_env("EBS_GB_MONTH_USD", 0.08) == 0.10


# --- unattached volumes ---------------------------------------------------


def test_find_unattached_volumes_costs_and_excludes(
    idle_finder: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    ec2 = FakeEC2(
        available_volumes=[
            {
                "VolumeId": "vol-idle",
                "Size": 100,
                "VolumeType": "gp3",
                "AvailabilityZone": "us-east-1a",
                "CreateTime": _now(),
                "Tags": _tags(Name="orphan"),
            },
            {
                "VolumeId": "vol-keep",
                "Size": 500,
                "VolumeType": "gp3",
                "Tags": _tags(**{"finops:keep": "true"}),
            },
        ]
    )
    monkeypatch.setattr(
        idle_finder, "_client", make_client_factory({"ec2": ec2})
    )
    findings = idle_finder._find_unattached_volumes({"finops:keep"}, 0.08)
    assert len(findings) == 1
    assert findings[0]["resource_id"] == "vol-idle"
    assert findings[0]["estimated_monthly_cost"] == 8.0


# --- idle addresses -------------------------------------------------------


def test_find_idle_addresses_skips_associated(
    idle_finder: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    ec2 = FakeEC2(
        addresses=[
            {"AllocationId": "eipalloc-idle", "PublicIp": "203.0.113.10", "Domain": "vpc"},
            {
                "AllocationId": "eipalloc-used",
                "AssociationId": "eipassoc-1",
                "PublicIp": "203.0.113.11",
            },
        ]
    )
    monkeypatch.setattr(
        idle_finder, "_client", make_client_factory({"ec2": ec2})
    )
    findings = idle_finder._find_idle_addresses(set(), 3.60)
    assert [f["resource_id"] for f in findings] == ["eipalloc-idle"]
    assert findings[0]["estimated_monthly_cost"] == 3.60


# --- stale snapshots ------------------------------------------------------


def test_find_stale_snapshots_age_and_orphaned(
    idle_finder: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    old = _now() - dt.timedelta(days=200)
    recent = _now() - dt.timedelta(days=5)
    ec2 = FakeEC2(
        all_volumes=[{"VolumeId": "vol-live"}],
        snapshots=[
            {  # old + orphaned -> flagged
                "SnapshotId": "snap-orphan",
                "StartTime": old,
                "VolumeId": "vol-gone",
                "VolumeSize": 100,
                "Tags": _tags(Name="old"),
            },
            {  # old but source volume still exists -> excluded in orphaned-only
                "SnapshotId": "snap-live-src",
                "StartTime": old,
                "VolumeId": "vol-live",
                "VolumeSize": 100,
            },
            {  # too recent -> excluded
                "SnapshotId": "snap-recent",
                "StartTime": recent,
                "VolumeId": "vol-gone",
                "VolumeSize": 100,
            },
        ],
    )
    monkeypatch.setattr(
        idle_finder, "_client", make_client_factory({"ec2": ec2})
    )
    findings = idle_finder._find_stale_snapshots(
        set(), snapshot_gb_month=0.05, age_days=90, orphaned_only=True
    )
    assert [f["resource_id"] for f in findings] == ["snap-orphan"]
    assert findings[0]["estimated_monthly_cost"] == 5.0
    assert findings[0]["detail"]["source_volume_exists"] is False


def test_stale_snapshots_all_old_when_not_orphaned_only(
    idle_finder: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    old = _now() - dt.timedelta(days=200)
    ec2 = FakeEC2(
        snapshots=[
            {"SnapshotId": "snap-a", "StartTime": old, "VolumeId": "v1", "VolumeSize": 10},
            {"SnapshotId": "snap-b", "StartTime": old, "VolumeId": "v2", "VolumeSize": 10},
        ]
    )
    monkeypatch.setattr(
        idle_finder, "_client", make_client_factory({"ec2": ec2})
    )
    findings = idle_finder._find_stale_snapshots(
        set(), snapshot_gb_month=0.05, age_days=90, orphaned_only=False
    )
    assert {f["resource_id"] for f in findings} == {"snap-a", "snap-b"}
    # In non-orphaned mode the existence flag is left unknown.
    assert findings[0]["detail"]["source_volume_exists"] is None


# --- handler --------------------------------------------------------------


def test_handler_full_report(
    idle_finder: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    old = _now() - dt.timedelta(days=200)
    ec2 = FakeEC2(
        available_volumes=[
            {"VolumeId": "vol-idle", "Size": 100, "VolumeType": "gp3", "Tags": _tags(Name="a")},
            {"VolumeId": "vol-keep", "Size": 999, "Tags": _tags(**{"finops:keep": "1"})},
        ],
        all_volumes=[
            {"VolumeId": "vol-idle", "Size": 100},
            {"VolumeId": "vol-keep", "Size": 999},
        ],
        addresses=[
            {"AllocationId": "eip-idle", "PublicIp": "203.0.113.9", "Domain": "vpc"},
            {"AllocationId": "eip-used", "AssociationId": "assoc", "PublicIp": "203.0.113.8"},
        ],
        snapshots=[
            {
                "SnapshotId": "snap-orphan",
                "StartTime": old,
                "VolumeId": "vol-gone",
                "VolumeSize": 100,
            }
        ],
    )
    s3, sns = RecordingS3(), RecordingSNS()
    monkeypatch.setattr(
        idle_finder,
        "_client",
        make_client_factory({"ec2": ec2, "s3": s3, "sns": sns}),
    )
    monkeypatch.setenv("REPORT_BUCKET", "finops-idle")
    monkeypatch.setenv("SNS_TOPIC_ARN", "arn:aws:sns:us-east-1:123456789012:idle")
    monkeypatch.setenv("ORPHANED_SNAPSHOTS_ONLY", "true")

    result = idle_finder.handler({}, None)

    # One volume + one EIP + one orphaned snapshot; kept resources excluded.
    assert result["resource_count"] == 3
    # 100*0.08 + 3.60 + 100*0.05 = 8.00 + 3.60 + 5.00
    assert result["total_estimated_monthly_cost"] == 16.60

    assert len(s3.put_calls) == 1
    put = s3.put_calls[0]
    assert put["Bucket"] == "finops-idle"
    assert put["ServerSideEncryption"] == "aws:kms"
    body = json.loads(put["Body"].decode("utf-8"))
    ids = {r["resource_id"] for r in body["idle_resources"]}
    assert ids == {"vol-idle", "eip-idle", "snap-orphan"}
    assert body["orphaned_snapshots_only"] is True

    assert len(sns.publish_calls) == 1
    assert "idle" in sns.publish_calls[0]["Subject"].lower()


def test_handler_skips_sns_when_topic_absent(
    idle_finder: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    ec2 = FakeEC2()
    s3, sns = RecordingS3(), RecordingSNS()
    monkeypatch.setattr(
        idle_finder,
        "_client",
        make_client_factory({"ec2": ec2, "s3": s3, "sns": sns}),
    )
    monkeypatch.setenv("REPORT_BUCKET", "finops-idle")
    monkeypatch.delenv("SNS_TOPIC_ARN", raising=False)

    result = idle_finder.handler({}, None)

    assert result["resource_count"] == 0
    assert len(s3.put_calls) == 1
    assert sns.publish_calls == []
