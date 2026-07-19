#!/usr/bin/env python3
"""Hash every non-ignored repository source file for benchmark provenance."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path


def snapshot(root: Path) -> dict:
    output = subprocess.check_output(
        ["git", "ls-files", "-co", "--exclude-standard", "-z"],
        cwd=root,
    )
    roots = ("Assets/", "Frameworks/", "Scripts/", "Sources/", "Tests/", "Vendor/")
    exact = {
        "Package.swift",
        "Package.resolved",
        "docs/japanese-live/model-recipes.json",
    }
    paths = sorted(
        path
        for path in output.decode().split("\0")
        if path
        and (path.startswith(roots) or path.startswith("docs/japanese-live/corpora/") or path in exact)
    )
    files = []
    for relative in paths:
        data = (root / relative).read_bytes()
        files.append({
            "path": relative,
            "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        })
    canonical = json.dumps(files, ensure_ascii=False, separators=(",", ":")).encode()
    return {
        "schemaVersion": 1,
        "scope": "benchmark-code-config-assets",
        "treeSHA256": hashlib.sha256(canonical).hexdigest(),
        "files": files,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--expect")
    args = parser.parse_args()
    result = snapshot(args.root.resolve())
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    print(result["treeSHA256"])
    if args.expect and result["treeSHA256"] != args.expect:
        raise SystemExit("repository sources changed during the benchmark")


if __name__ == "__main__":
    main()
