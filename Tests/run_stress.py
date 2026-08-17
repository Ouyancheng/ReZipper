#!/usr/bin/env python3
"""List, test, extract, and peel every stress archive through rezipper-cli."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent


class Fail(Exception):
    pass


def run_cli(cli: Path, lib: Path, extra: list[str], password: str = "", nest: list[int] | None = None) -> str:
    cmd = [str(cli), "--lib", str(lib)]
    if password:
        cmd += ["--password", password]
    if nest:
        cmd += ["--nest", ",".join(str(i) for i in nest)]
    cmd += extra
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise Fail(f"{' '.join(extra)} failed ({proc.returncode}): {proc.stderr.strip() or proc.stdout.strip()}")
    return proc.stdout


def parse_list(stdout: str) -> tuple[dict, list[dict]]:
    lines = [line for line in stdout.splitlines() if line.strip()]
    if not lines:
        raise Fail("empty list output")
    header = {}
    for part in lines[0].split():
        if "=" in part:
            key, value = part.split("=", 1)
            header[key] = value
    items = []
    for line in lines[1:]:
        kind = line[0]
        rest = line[2:]
        index_s, size_s, path = rest.split("\t", 2)
        items.append({"dir": kind == "D", "index": int(index_s), "size": int(size_s), "path": path})
    return header, items


def find_item(items: list[dict], path: str) -> dict:
    for item in items:
        if item["path"] == path:
            return item
    raise Fail(f"missing path {path!r}; have {[i['path'] for i in items]}")


def check_paths(items: list[dict], expected: list[str]) -> None:
    have = {item["path"] for item in items}
    missing = [path for path in expected if path not in have]
    if missing:
        raise Fail(f"missing {missing}; have {sorted(have)}")


def extract_and_check(
    cli: Path,
    lib: Path,
    archive: Path,
    spec: dict,
    password: str,
    nest: list[int] | None,
    listed: list[dict] | None = None,
) -> None:
    files = spec.get("expect_files") or {}
    if spec.get("skip_extract") or spec.get("skip_full_extract_check") and not files:
        return
    if not files:
        return
    dest = Path(tempfile.mkdtemp(prefix="rz-stress-"))
    try:
        run_cli(cli, lib, ["extract", str(archive), str(dest)], password=password, nest=nest)
        for rel, text in files.items():
            expected = text.encode("utf-8")
            candidates = [dest / rel, dest / Path(rel).name]
            if listed:
                for item in listed:
                    if not item["dir"]:
                        candidates.append(dest / item["path"])
            path = next((p for p in candidates if p.is_file()), None)
            if path is None and spec.get("locale_sensitive"):
                for found in dest.rglob("*"):
                    if found.is_file() and found.read_bytes() == expected:
                        path = found
                        break
            if path is None:
                raise Fail(f"extracted file missing: {rel} (under {dest})")
            got = path.read_bytes()
            if got != expected:
                raise Fail(f"{rel} content mismatch: {got!r} != {expected!r}")
    finally:
        shutil.rmtree(dest, ignore_errors=True)


def resolve_nest(cli: Path, lib: Path, archive: Path, password: str, chain: list[str]) -> list[int]:
    nest: list[int] = []
    for name in chain:
        _, items = parse_list(run_cli(cli, lib, ["list", str(archive)], password=password, nest=nest or None))
        nest.append(find_item(items, name)["index"])
    return nest


def run_one(cli: Path, lib: Path, tests_dir: Path, name: str, spec: dict) -> None:
    archive = tests_dir / spec["file"]
    if spec.get("external"):
        archive = ROOT / spec["file"]
    if not archive.exists():
        raise Fail(f"archive not found: {archive}")

    password = spec.get("password") or ""
    if spec.get("require_password_to_list"):
        try:
            run_cli(cli, lib, ["list", str(archive)])
            raise Fail("listing encrypted headers succeeded without a password")
        except Fail as exc:
            if "listing encrypted headers succeeded" in str(exc):
                raise
    _, items = parse_list(run_cli(cli, lib, ["list", str(archive)], password=password))

    if spec.get("expect_file_count") is not None:
        files = sum(1 for item in items if not item["dir"])
        if files != spec["expect_file_count"]:
            raise Fail(f"file count {files} != {spec['expect_file_count']}")
    if spec.get("expect_folder_count") is not None:
        folders = sum(1 for item in items if item["dir"])
        if folders != spec["expect_folder_count"]:
            raise Fail(f"folder count {folders} != {spec['expect_folder_count']}")

    if spec.get("expect_paths") and not spec.get("locale_sensitive"):
        check_paths(items, spec["expect_paths"])
    if spec.get("expect_any_paths"):
        last_error = None
        for candidate in spec["expect_any_paths"]:
            try:
                check_paths(items, candidate)
                last_error = None
                break
            except Fail as exc:
                last_error = exc
        if last_error:
            raise Fail(f"none of the accepted listings matched: {last_error}")

    run_cli(cli, lib, ["test", str(archive)], password=password)
    extract_and_check(cli, lib, archive, spec, password, None, items)

    for nested in spec.get("nested") or []:
        if "index" in nested:
            nest = [int(nested["index"])]
        else:
            chain = [nested["path"]]
            if nested.get("then"):
                chain.append(nested["then"])
            nest = resolve_nest(cli, lib, archive, password, chain)
        _, nitems = parse_list(run_cli(cli, lib, ["list", str(archive)], password=password, nest=nest))
        if nested.get("expect_paths"):
            check_paths(nitems, nested["expect_paths"])
        run_cli(cli, lib, ["test", str(archive)], password=password, nest=nest)
        extract_and_check(cli, lib, archive, nested, password, nest, nitems)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", type=Path, default=ROOT)
    parser.add_argument("--cli", type=Path, default=REPO / "build" / "rezipper-cli")
    parser.add_argument("--lib", type=Path, default=REPO / "build" / "ReZipper.app" / "Contents" / "Frameworks" / "7z.so")
    parser.add_argument("--only", action="append", default=[])
    args = parser.parse_args()
    manifest_path = args.dir / "manifest.json"
    if not manifest_path.exists():
        print(f"missing {manifest_path}; run Tests/generate_stress.py first", file=sys.stderr)
        return 2
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    failed = 0
    ran = 0
    for name, spec in manifest["archives"].items():
        if args.only and name not in args.only and spec.get("file") not in args.only:
            continue
        ran += 1
        try:
            run_one(args.cli, args.lib, args.dir, name, spec)
            print(f"ok  {name}")
        except Fail as exc:
            failed += 1
            print(f"FAIL {name}: {exc}", file=sys.stderr)
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print(f"FAIL {name}: {type(exc).__name__}: {exc}", file=sys.stderr)
    print(f"{ran - failed}/{ran} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
