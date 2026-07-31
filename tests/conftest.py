"""Shared pytest fixtures for the FinOps Lambda unit tests.

Both Lambda handlers live in files named ``handler.py`` under different
directories, so they are loaded by path under distinct module names to avoid an
import-name collision. Each fixture returns a freshly imported module.
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import types

import pytest

_ROOT = pathlib.Path(__file__).resolve().parent.parent


def _load(module_name: str, relative_path: str) -> types.ModuleType:
    spec = importlib.util.spec_from_file_location(
        module_name, _ROOT / relative_path
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def rightsizing() -> types.ModuleType:
    """The Compute Optimizer rightsizing report handler module."""
    return _load("rightsizing_handler", "lambda/rightsizing/handler.py")


@pytest.fixture()
def idle_finder() -> types.ModuleType:
    """The idle-resource finder handler module."""
    return _load("idle_finder_handler", "lambda/idle-finder/handler.py")


@pytest.fixture(autouse=True)
def _dummy_aws_credentials(monkeypatch: pytest.MonkeyPatch) -> None:
    """Guard against any accidental real AWS call.

    The handlers wrap ``boto3.client`` in a factory that the tests monkeypatch,
    so no network call should ever happen. Setting placeholder credentials
    keeps a stray call from reaching a real account if a patch is ever missed.
    """
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
