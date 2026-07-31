"""In-memory boto3 client doubles shared by the FinOps Lambda tests.

Each fake records the calls made against it so a test can assert on the request
that would have been sent, and returns canned data so the handler logic can be
exercised without touching AWS.
"""

from __future__ import annotations

from typing import Any


class RecordingS3:
    """Captures ``put_object`` calls."""

    def __init__(self) -> None:
        self.put_calls: list[dict[str, Any]] = []

    def put_object(self, **kwargs: Any) -> dict[str, Any]:
        self.put_calls.append(kwargs)
        return {"ETag": "fake-etag"}


class RecordingSNS:
    """Captures ``publish`` calls."""

    def __init__(self) -> None:
        self.publish_calls: list[dict[str, Any]] = []

    def publish(self, **kwargs: Any) -> dict[str, Any]:
        self.publish_calls.append(kwargs)
        return {"MessageId": "fake-message-id"}


class FakeComputeOptimizer:
    """Serves Compute Optimizer Get*Recommendations responses.

    Each recommendation family is stored as a list of pages; a page is a dict
    already shaped like the real API response (items key + optional nextToken).
    A missing family yields a single empty page.
    """

    def __init__(self, pages: dict[str, list[dict[str, Any]]] | None = None) -> None:
        self._pages = pages or {}
        self.calls: dict[str, int] = {}

    def _serve(self, api: str, items_key: str, **kwargs: Any) -> dict[str, Any]:
        self.calls[api] = self.calls.get(api, 0) + 1
        pages = self._pages.get(api)
        if not pages:
            return {items_key: []}
        token = kwargs.get("nextToken")
        index = int(token) if token else 0
        page = pages[index]
        response = dict(page)
        if index + 1 < len(pages):
            response["nextToken"] = str(index + 1)
        else:
            response.pop("nextToken", None)
        return response

    def get_ec2_instance_recommendations(self, **kwargs: Any) -> dict[str, Any]:
        return self._serve(
            "ec2", "instanceRecommendations", **kwargs
        )

    def get_auto_scaling_group_recommendations(
        self, **kwargs: Any
    ) -> dict[str, Any]:
        return self._serve(
            "asg", "autoScalingGroupRecommendations", **kwargs
        )

    def get_ebs_volume_recommendations(self, **kwargs: Any) -> dict[str, Any]:
        return self._serve("ebs", "volumeRecommendations", **kwargs)

    def get_lambda_function_recommendations(
        self, **kwargs: Any
    ) -> dict[str, Any]:
        return self._serve(
            "lambda", "lambdaFunctionRecommendations", **kwargs
        )


class _Paginator:
    def __init__(self, pages_fn: Any, op: str) -> None:
        self._pages_fn = pages_fn
        self._op = op

    def paginate(self, **kwargs: Any) -> list[dict[str, Any]]:
        return self._pages_fn(self._op, **kwargs)


class FakeEC2:
    """Serves describe_volumes / describe_addresses / describe_snapshots.

    ``available_volumes`` is returned when the status=available filter is set;
    ``all_volumes`` (defaults to the available set) is returned for the
    unfiltered call used to resolve which volumes still exist.
    """

    def __init__(
        self,
        available_volumes: list[dict[str, Any]] | None = None,
        all_volumes: list[dict[str, Any]] | None = None,
        addresses: list[dict[str, Any]] | None = None,
        snapshots: list[dict[str, Any]] | None = None,
    ) -> None:
        self.available_volumes = available_volumes or []
        self.all_volumes = (
            all_volumes if all_volumes is not None else list(self.available_volumes)
        )
        self.addresses = addresses or []
        self.snapshots = snapshots or []

    def get_paginator(self, op: str) -> _Paginator:
        return _Paginator(self._pages, op)

    def _pages(self, op: str, **kwargs: Any) -> list[dict[str, Any]]:
        if op == "describe_volumes":
            filters = kwargs.get("Filters", [])
            want_available = any(
                f.get("Name") == "status" and "available" in f.get("Values", [])
                for f in filters
            )
            volumes = self.available_volumes if want_available else self.all_volumes
            return [{"Volumes": volumes}]
        if op == "describe_snapshots":
            return [{"Snapshots": self.snapshots}]
        raise ValueError(f"unexpected paginator op: {op}")

    def describe_addresses(self, **kwargs: Any) -> dict[str, Any]:
        return {"Addresses": self.addresses}


def make_client_factory(mapping: dict[str, Any]) -> Any:
    """Return a ``_client`` replacement resolving a service name to a fake."""

    def factory(service: str) -> Any:
        try:
            return mapping[service]
        except KeyError as exc:  # pragma: no cover - test wiring error
            raise AssertionError(f"unexpected client requested: {service}") from exc

    return factory
