#!/usr/bin/env python3
"""Atomically replace a runtime venv link without following its old target."""

from __future__ import annotations

import os
import shutil
import sys
import tempfile


def publish(stage: str, link: str) -> None:
    if not os.path.isdir(stage):
        raise FileNotFoundError(stage)

    parent = os.path.dirname(os.path.abspath(link)) or "."
    os.makedirs(parent, exist_ok=True)
    temp_dir = tempfile.mkdtemp(prefix=".nexvoice-venv-link-", dir=parent)
    temp_link = os.path.join(temp_dir, "venv")
    try:
        os.symlink(os.path.abspath(stage), temp_link)
        # os.replace renames the symlink itself on macOS, even when link points
        # at a directory; it never moves temp_link into the old target.
        os.replace(temp_link, link)
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} STAGE_VENV VENV_LINK", file=sys.stderr)
        return 2
    try:
        publish(argv[1], argv[2])
    except (OSError, ValueError) as error:
        print(f"error: could not publish runtime venv: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
