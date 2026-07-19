#!/usr/bin/env python3
"""Record the local runtimes that execute the Japanese benchmark."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path


def command(arguments: list[str], cwd: Path | None = None) -> str:
    return subprocess.check_output(arguments, cwd=cwd, text=True, stderr=subprocess.STDOUT).strip()


def git_tree(path: Path) -> dict:
    return {
        "path": str(path),
        "head": command(["git", "rev-parse", "HEAD"], path),
        "dirty": bool(command(["git", "status", "--porcelain", "--untracked-files=no"], path)),
    }


def python_environment(path: Path) -> dict:
    distributions = command([
        str(path),
        "-c",
        "import importlib.metadata as m; print('\\n'.join(sorted(f'{d.metadata[\"Name\"]}=={d.version}' for d in m.distributions())))",
    ]).splitlines()
    return {
        "executable": str(path.resolve()),
        "version": command([str(path), "--version"]),
        "distributions": distributions,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    root = args.root.resolve()
    checkout_paths = sorted(path for path in (root / ".build/checkouts").iterdir() if path.is_dir())
    extra_repositories = [
        root / ".build/benchmarks/japanese-live/tools/whisperlivekit/5874bdeeaddf968ab73e005eb287e1b597b0eb37/source",
        root / ".build/benchmarks/japanese-live/tools/silero-vad/7e30209a3e901f9842f81b225f3e93d8199902b1",
    ]
    python_paths = [
        root / ".build/benchmarks/japanese-live/tools/mlx-whisper/0.4.3/venv/bin/python",
        root / ".build/benchmarks/japanese-live/tools/whispermlx/v3.12.2/venv/bin/python",
        root / ".build/benchmarks/japanese-live/tools/whisperlivekit/5874bdeeaddf968ab73e005eb287e1b597b0eb37/venv/bin/python",
    ]
    repositories = [git_tree(path) for path in checkout_paths + extra_repositories]
    details = {
        "schemaVersion": 1,
        "macOS": command(["sw_vers"]),
        "xcode": command(["xcodebuild", "-version"]),
        "swift": command(["swift", "--version"]),
        "architecture": command(["uname", "-m"]),
        "hardwareModel": command(["sysctl", "-n", "hw.model"]),
        "memoryBytes": int(command(["sysctl", "-n", "hw.memsize"])),
        "repositories": repositories,
        "pythonEnvironments": [python_environment(path) for path in python_paths],
    }
    canonical = json.dumps(details, ensure_ascii=False, separators=(",", ":")).encode()
    result = {
        **details,
        "valid": all(not repository["dirty"] for repository in repositories),
        "runtimeSHA256": hashlib.sha256(canonical).hexdigest(),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(result["runtimeSHA256"])
    if not result["valid"]:
        raise SystemExit("a benchmark runtime repository contains tracked modifications")


if __name__ == "__main__":
    main()
