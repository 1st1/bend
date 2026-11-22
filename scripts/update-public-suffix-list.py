#!/usr/bin/env python3
"""Compatibility entry point for refreshing the bundled domain table."""
import os
from pathlib import Path
import sys

os.execvp("swift", ["swift", str(Path(__file__).with_suffix(".swift")), *sys.argv[1:]])
