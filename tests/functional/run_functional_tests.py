#!/usr/bin/env python3
"""CLI entrypoint: run functional API tests via pytest."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest


def main() -> int:
    root = Path(__file__).resolve().parent
    args = [
        str(root / "test_analyzer_api.py"),
        "-v",
        "--tb=short",
    ] + sys.argv[1:]
    return pytest.main(args)


if __name__ == "__main__":
    raise SystemExit(main())
