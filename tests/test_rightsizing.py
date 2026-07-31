"""Unit tests for the Compute Optimizer rightsizing report handler."""

from __future__ import annotations

import json
from typing import Any

import pytest

from fakes import (
    FakeComputeOptimizer,
    RecordingS3,
    RecordingSNS,
    make_client_factory,
)


def _savings(value: float) -> dict[str, Any]:
    return {"savingsOpportunity": {"estimatedMonthlySavings": {"value": value}}}


def _ec2_rec(
    arn: str,
    finding: str,
    options: list[dict[str, Any]],
    current: str = "m5.2xlarge",
) -> dict[str, Any]:
    return {
        "instanceArn": arn,
        "instanceName": arn.split("/")[-1],
        "finding": finding,
        "currentInstanceType": current,
        "recommendationOptions": options,
    }


# --- pure helpers ---------------------------------------------------------


def test_monthly_savings_extracts_nested_value(rightsizing: Any) -> None:
    assert rightsizing._monthly_savings(_savings(42.5)) == 42.5


def test_monthly_savings_missing_is_zero(rightsizing: Any) -> None:
    assert rightsizing._monthly_savings({}) == 0.0
    assert rightsizing._monthly_savings({"savingsOpportunity": {}}) == 0.0


def test_monthly_savings_bad_value_is_zero(rightsizing: Any) -> None:
    entry = {"savingsOpportunity": {"estimatedMonthlySavings": {"value": "n/a"}}}
    assert rightsizing._monthly_savings(entry) == 0.0


def test_pick_option_matches_requested_rank(rightsizing: Any) -> None:
    options = [
        {"rank": 1, "instanceType": "m5.xlarge", **_savings(10.0)},
        {"rank": 2, "instanceType": "m5.large", **_savings(25.0)},
    ]
    chosen = rightsizing._pick_option(options, 2)
    assert chosen["instanceType"] == "m5.large"


def test_pick_option_falls_back_to_max_savings(rightsizing: Any) -> None:
    options = [
        {"rank": 1, "instanceType": "m5.xlarge", **_savings(10.0)},
        {"rank": 2, "instanceType": "m5.large", **_savings(25.0)},
    ]
    # No option carries rank 3 -> greatest-savings option wins.
    chosen = rightsizing._pick_option(options, 3)
    assert chosen["instanceType"] == "m5.large"


def test_pick_option_empty_is_none(rightsizing: Any) -> None:
    assert rightsizing._pick_option([], 1) is None


def test_paginate_walks_next_token(rightsizing: Any) -> None:
    co = FakeComputeOptimizer(
        {
            "ec2": [
                {"instanceRecommendations": [{"instanceArn": "a"}]},
                {"instanceRecommendations": [{"instanceArn": "b"}]},
            ]
        }
    )
    items = list(
        rightsizing._paginate(
            co.get_ec2_instance_recommendations, "instanceRecommendations"
        )
    )
    assert [i["instanceArn"] for i in items] == ["a", "b"]
    assert co.calls["ec2"] == 2


# --- collectors -----------------------------------------------------------


def test_collect_ec2_skips_optimized(
    rightsizing: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    co = FakeComputeOptimizer(
        {
            "ec2": [
                {
                    "instanceRecommendations": [
                        _ec2_rec(
                            "arn:aws:ec2:...:instance/i-over",
                            "Overprovisioned",
                            [{"rank": 1, "instanceType": "m5.large", **_savings(30.0)}],
                        ),
                        _ec2_rec(
                            "arn:aws:ec2:...:instance/i-ok",
                            "Optimized",
                            [{"rank": 1, "instanceType": "m5.2xlarge", **_savings(0.0)}],
                        ),
                    ]
                }
            ]
        }
    )
    monkeypatch.setattr(
        rightsizing, "_client", make_client_factory({"compute-optimizer": co})
    )
    findings = rightsizing._collect_ec2(1)
    assert len(findings) == 1
    assert findings[0]["resource_type"] == "EC2Instance"
    assert findings[0]["recommended"] == "m5.large"
    assert findings[0]["estimated_monthly_savings"] == 30.0


# --- report assembly ------------------------------------------------------


def test_build_report_applies_threshold_and_sorts(
    rightsizing: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    co = FakeComputeOptimizer(
        {
            "ec2": [
                {
                    "instanceRecommendations": [
                        _ec2_rec(
                            "arn:aws:ec2:...:instance/i-big",
                            "Overprovisioned",
                            [{"rank": 1, "instanceType": "m5.large", **_savings(50.0)}],
                        ),
                        _ec2_rec(
                            "arn:aws:ec2:...:instance/i-tiny",
                            "Overprovisioned",
                            [{"rank": 1, "instanceType": "m5.large", **_savings(0.5)}],
                        ),
                    ]
                }
            ]
        }
    )
    monkeypatch.setattr(
        rightsizing, "_client", make_client_factory({"compute-optimizer": co})
    )
    report = rightsizing._build_report(rank=1, threshold=1.0)
    # The sub-threshold recommendation is dropped.
    assert report["resource_count"] == 1
    assert report["total_estimated_monthly_savings"] == 50.0
    assert report["by_resource_type"]["EC2Instance"]["count"] == 1


def test_collector_failure_does_not_sink_run(
    rightsizing: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    def boom(_rank: int) -> list[dict[str, Any]]:
        raise RuntimeError("compute optimizer unavailable")

    monkeypatch.setitem(rightsizing._COLLECTORS, "EC2Instance", boom)
    # Other families return nothing (empty compute-optimizer), run still succeeds.
    co = FakeComputeOptimizer({})
    monkeypatch.setattr(
        rightsizing, "_client", make_client_factory({"compute-optimizer": co})
    )
    report = rightsizing._build_report(rank=1, threshold=1.0)
    assert report["resource_count"] == 0
    assert report["by_resource_type"]["EC2Instance"]["count"] == 0


# --- handler --------------------------------------------------------------


def _wire_handler(
    rightsizing: Any,
    monkeypatch: pytest.MonkeyPatch,
    co: FakeComputeOptimizer,
) -> tuple[RecordingS3, RecordingSNS]:
    s3, sns = RecordingS3(), RecordingSNS()
    monkeypatch.setattr(
        rightsizing,
        "_client",
        make_client_factory(
            {"compute-optimizer": co, "s3": s3, "sns": sns}
        ),
    )
    monkeypatch.setenv("REPORT_BUCKET", "finops-reports")
    monkeypatch.setenv("SNS_TOPIC_ARN", "arn:aws:sns:us-east-1:123456789012:finops")
    return s3, sns


def test_handler_writes_kms_report_and_publishes(
    rightsizing: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    co = FakeComputeOptimizer(
        {
            "ec2": [
                {
                    "instanceRecommendations": [
                        _ec2_rec(
                            "arn:aws:ec2:...:instance/i-1",
                            "Overprovisioned",
                            [{"rank": 1, "instanceType": "m5.large", **_savings(120.0)}],
                        )
                    ]
                }
            ]
        }
    )
    s3, sns = _wire_handler(rightsizing, monkeypatch, co)

    result = rightsizing.handler({}, None)

    assert result["resource_count"] == 1
    assert result["total_estimated_monthly_savings"] == 120.0
    # Report persisted with KMS server-side encryption.
    assert len(s3.put_calls) == 1
    put = s3.put_calls[0]
    assert put["Bucket"] == "finops-reports"
    assert put["ServerSideEncryption"] == "aws:kms"
    body = json.loads(put["Body"].decode("utf-8"))
    assert body["recommendations"][0]["resource_arn"].endswith("i-1")
    # Summary published to SNS.
    assert len(sns.publish_calls) == 1
    assert "rightsizing" in sns.publish_calls[0]["Subject"].lower()


def test_handler_skips_sns_when_topic_absent(
    rightsizing: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    co = FakeComputeOptimizer({})
    s3, sns = _wire_handler(rightsizing, monkeypatch, co)
    monkeypatch.delenv("SNS_TOPIC_ARN", raising=False)

    rightsizing.handler({}, None)

    assert len(s3.put_calls) == 1
    assert sns.publish_calls == []


def test_handler_clamps_recommendation_rank(
    rightsizing: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    captured: dict[str, int] = {}

    def fake_build(rank: int, threshold: float) -> dict[str, Any]:
        captured["rank"] = rank
        return {
            "generated_at": "now",
            "recommendation_rank": rank,
            "savings_threshold": threshold,
            "total_estimated_monthly_savings": 0.0,
            "resource_count": 0,
            "by_resource_type": {},
            "recommendations": [],
        }

    s3, _sns = _wire_handler(rightsizing, monkeypatch, FakeComputeOptimizer({}))
    monkeypatch.setattr(rightsizing, "_build_report", fake_build)
    monkeypatch.setenv("RECOMMENDATION_RANK", "9")

    rightsizing.handler({}, None)
    # 9 is clamped into the valid 1-3 range.
    assert captured["rank"] == 3
