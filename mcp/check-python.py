#!/usr/bin/env python3
"""Return a stable exit code for the minimum supported Python version."""

import sys


if sys.version_info[:2] < (3, 10):
    raise SystemExit(10)
raise SystemExit(0)
