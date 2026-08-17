#!/usr/bin/env python3
"""Build the ReZipper stress-archive set (siblings of 01history.zip)."""

from __future__ import annotations

import argparse
import io
import json
import shutil
import struct
import subprocess
import sys
import tarfile
import time
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent


def dos_datetime(ts: float | None = None) -> tuple[int, int]:
    t = time.localtime(ts or time.time())
    return (
        (t.tm_hour << 11) | (t.tm_min << 5) | (t.tm_sec // 2),
        ((t.tm_year - 1980) << 9) | (t.tm_mon << 5) | t.tm_mday,
    )


class RawZip:
    """ZIP writer that can emit legacy (GBK / Shift-JIS / …) names without the UTF-8 flag."""

    def __init__(self) -> None:
        self._entries: list[tuple[bytes, bytes, bytes, int, int, int]] = []

    def add(
        self,
        name: str,
        data: bytes = b"",
        *,
        encoding: str = "utf-8",
        utf8_flag: bool = True,
        directory: bool = False,
    ) -> None:
        if directory and not name.endswith("/"):
            name += "/"
        name_b = name.encode(encoding)
        method = 0
        compressed = data
        if data and not directory:
            compressed = zlib.compress(data, 9)[2:-4]
            method = 8
        flags = 0x0800 if utf8_flag else 0
        crc = zlib.crc32(data) & 0xFFFFFFFF
        self._entries.append((name_b, data, compressed, flags, method, crc))

    def dumps(self) -> bytes:
        out = io.BytesIO()
        central = io.BytesIO()
        dos_time, dos_date = dos_datetime()
        offset = 0
        for name_b, data, compressed, flags, method, crc in self._entries:
            local = struct.pack(
                "<4sHHHHHLLLHH",
                b"PK\x03\x04",
                20,
                flags,
                method,
                dos_time,
                dos_date,
                crc,
                len(compressed),
                len(data),
                len(name_b),
                0,
            )
            out.write(local)
            out.write(name_b)
            out.write(compressed)
            ext_attr = 0x10 if name_b.endswith(b"/") else 0
            central.write(
                struct.pack(
                    "<4sHHHHHHLLLHHHHHLL",
                    b"PK\x01\x02",
                    20,
                    20,
                    flags,
                    method,
                    dos_time,
                    dos_date,
                    crc,
                    len(compressed),
                    len(data),
                    len(name_b),
                    0,
                    0,
                    0,
                    0,
                    ext_attr,
                    offset,
                )
            )
            central.write(name_b)
            offset += len(local) + len(name_b) + len(compressed)
        cd = central.getvalue()
        out.write(cd)
        out.write(
            struct.pack(
                "<4sHHHHLLH",
                b"PK\x05\x06",
                0,
                0,
                len(self._entries),
                len(self._entries),
                len(cd),
                offset,
                0,
            )
        )
        return out.getvalue()

    def write(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(self.dumps())


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def cli_create(
    cli: Path,
    lib: Path,
    archive: Path,
    files: list[Path],
    *,
    password: str = "",
    encrypt_headers: bool = False,
    solid: bool = True,
) -> None:
    cmd = [str(cli), "--lib", str(lib)]
    if password:
        cmd += ["--password", password]
    if encrypt_headers:
        cmd.append("--encrypt-headers")
    if not solid:
        cmd.append("--no-solid")
    cmd += ["create", str(archive), *[str(p) for p in files]]
    subprocess.check_call(cmd)


def make_tar(path: Path, members: list[tuple[str, bytes]], *, symlink: tuple[str, str] | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(path, "w") as tar:
        for name, data in members:
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mtime = int(time.time())
            tar.addfile(info, io.BytesIO(data))
        if symlink:
            info = tarfile.TarInfo(symlink[0])
            info.type = tarfile.SYMTYPE
            info.linkname = symlink[1]
            info.mtime = int(time.time())
            tar.addfile(info)


def compress_copy(src: Path, dest: Path, mode: str) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if mode == "gz":
        import gzip

        with open(src, "rb") as inf, gzip.open(dest, "wb", compresslevel=9) as out:
            shutil.copyfileobj(inf, out)
    elif mode == "bz2":
        import bz2

        dest.write_bytes(bz2.compress(src.read_bytes(), 9))
    elif mode == "xz":
        import lzma

        dest.write_bytes(lzma.compress(src.read_bytes()))
    else:
        raise ValueError(mode)


def generate(out_dir: Path, cli: Path | None, lib: Path | None) -> dict:
    manifest: dict = {
        "password": "secret",
        "archives": {},
    }

    def record(name: str, **kwargs) -> Path:
        path = out_dir / name
        entry = {"file": name, **kwargs}
        manifest["archives"][name] = entry
        return path

    # 02 — same class as 01history.zip: GBK names + explicit "folder/" entry.
    z = RawZip()
    z.add("0-1刷新", directory=True, encoding="gbk", utf8_flag=False)
    z.add("0-1刷新/说明.txt", "历史文件夹应出现在根目录\n".encode(), encoding="gbk", utf8_flag=False)
    z.add("0-1刷新/OmniLang演示.pptx.txt", "placeholder slide\n".encode(), encoding="gbk", utf8_flag=False)
    z.add("0-1刷新/子目录", directory=True, encoding="gbk", utf8_flag=False)
    z.add("0-1刷新/子目录/深层.txt", "nested gbk\n".encode(), encoding="gbk", utf8_flag=False)
    p = record(
        "02-gbk-folders.zip",
        like="01history.zip",
        notes="GBK, no UTF-8 flag, trailing-slash directory entries. Root folder must appear.",
        expect_paths=["0-1刷新", "0-1刷新/说明.txt", "0-1刷新/OmniLang演示.pptx.txt", "0-1刷新/子目录", "0-1刷新/子目录/深层.txt"],
        expect_files={"0-1刷新/说明.txt": "历史文件夹应出现在根目录\n"},
    )
    z.write(p)

    # 03 — GBK files only; folders are implicit (no directory entries).
    z = RawZip()
    z.add("资料/汉化/说明.txt", "implicit folders\n".encode(), encoding="gbk", utf8_flag=False)
    z.add("资料/汉化/存档.sav.txt", "save\n".encode(), encoding="gbk", utf8_flag=False)
    p = record(
        "03-gbk-implicit.zip",
        notes="GBK files with parent paths but no directory entries.",
        expect_paths=["资料/汉化/说明.txt", "资料/汉化/存档.sav.txt"],
        expect_files={"资料/汉化/说明.txt": "implicit folders\n"},
    )
    z.write(p)

    # 04 — Shift-JIS
    z = RawZip()
    z.add("日本語フォルダ", directory=True, encoding="shift_jis", utf8_flag=False)
    z.add("日本語フォルダ/説明.txt", "シフトJIS\n".encode(), encoding="shift_jis", utf8_flag=False)
    p = record(
        "04-shiftjis.zip",
        notes="Shift-JIS names, no UTF-8 flag.",
        expect_paths=["日本語フォルダ", "日本語フォルダ/説明.txt"],
        expect_files={"日本語フォルダ/説明.txt": "シフトJIS\n"},
    )
    z.write(p)

    # 05 — Big5
    z = RawZip()
    z.add("繁體中文", directory=True, encoding="big5", utf8_flag=False)
    z.add("繁體中文/說明.txt", "Big5 編碼\n".encode(), encoding="big5", utf8_flag=False)
    p = record(
        "05-big5.zip",
        notes="Big5 names, no UTF-8 flag.",
        expect_paths=["繁體中文", "繁體中文/說明.txt"],
        expect_files={"繁體中文/說明.txt": "Big5 編碼\n"},
    )
    z.write(p)

    # 06 — EUC-KR
    z = RawZip()
    z.add("한글폴더", directory=True, encoding="euc_kr", utf8_flag=False)
    z.add("한글폴더/설명.txt", "EUC-KR\n".encode(), encoding="euc_kr", utf8_flag=False)
    p = record(
        "06-euckr.zip",
        notes="EUC-KR names, no UTF-8 flag.",
        expect_paths=["한글폴더", "한글폴더/설명.txt"],
        expect_files={"한글폴더/설명.txt": "EUC-KR\n"},
    )
    z.write(p)

    # 07 — UTF-8 flag set (control)
    z = RawZip()
    z.add("中文文件夹", directory=True, encoding="utf-8", utf8_flag=True)
    z.add("中文文件夹/你好.txt", "utf-8 ok\n".encode(), encoding="utf-8", utf8_flag=True)
    z.add("中文文件夹/emoji-📦.txt", "box\n".encode(), encoding="utf-8", utf8_flag=True)
    p = record(
        "07-utf8-flag.zip",
        notes="Language encoding flag set; names are already UTF-8.",
        expect_paths=["中文文件夹", "中文文件夹/你好.txt", "中文文件夹/emoji-📦.txt"],
        expect_files={"中文文件夹/你好.txt": "utf-8 ok\n"},
    )
    z.write(p)

    # 08 — awkward but legal names
    z = RawZip()
    specials = [
        ("file with spaces.txt", b"spaces\n"),
        (".hidden", b"dotfile\n"),
        ("dots...txt", b"dots\n"),
        ("name#hash%.txt", b"hash\n"),
        ("brackets[1].txt", b"brackets\n"),
        ("quotes'n.txt", b"quotes\n"),
        ("café.txt", "café\n".encode()),
        ("trailing ", b"space-name\n"),
    ]
    for name, data in specials:
        z.add(name, data, encoding="utf-8", utf8_flag=True)
    p = record(
        "08-special-names.zip",
        notes="Spaces, dots, #, %, brackets, quotes, NFC accent.",
        expect_paths=[name for name, _ in specials],
        expect_files={"file with spaces.txt": "spaces\n", "café.txt": "café\n"},
    )
    z.write(p)

    # 09 — empty folder + zero-byte file
    z = RawZip()
    z.add("empty-dir", directory=True, encoding="utf-8", utf8_flag=True)
    z.add("zero.txt", b"", encoding="utf-8", utf8_flag=True)
    z.add("empty-dir/also-empty", directory=True, encoding="utf-8", utf8_flag=True)
    p = record(
        "09-empty-zero.zip",
        notes="Empty directories and a zero-byte file.",
        expect_paths=["empty-dir", "zero.txt", "empty-dir/also-empty"],
        expect_files={"zero.txt": ""},
    )
    z.write(p)

    # 10 — deep tree + siblings (sidebar / path bar)
    z = RawZip()
    deep = "/".join(f"L{i:02d}" for i in range(1, 13))
    z.add(deep, directory=True, encoding="utf-8", utf8_flag=True)
    z.add(f"{deep}/leaf.txt", b"bottom\n", encoding="utf-8", utf8_flag=True)
    for i in range(8):
        z.add(f"sibling-{i:02d}.txt", f"s{i}\n".encode(), encoding="utf-8", utf8_flag=True)
    p = record(
        "10-deep-tree.zip",
        notes="12-level folder plus root siblings for the path bar and sidebar.",
        expect_paths=[deep, f"{deep}/leaf.txt", "sibling-00.txt", "sibling-07.txt"],
        expect_files={f"{deep}/leaf.txt": "bottom\n"},
    )
    z.write(p)

    # 11 — Windows backslashes in the stored name
    z = RawZip()
    z.add("win\\folder\\readme.txt", b"backslash\n", encoding="utf-8", utf8_flag=True)
    p = record(
        "11-windows-backslash.zip",
        notes="Central-directory name uses backslashes; engine should normalize to /.",
        expect_paths=["win/folder/readme.txt"],
        expect_files={"win/folder/readme.txt": "backslash\n"},
    )
    z.write(p)

    # 12 — absolute-looking path (leading slash stripped)
    z = RawZip()
    z.add("/absolute/rooted.txt", b"rooted\n", encoding="utf-8", utf8_flag=True)
    p = record(
        "12-absolute-path.zip",
        notes="Stored as /absolute/rooted.txt; listing should drop the leading slash.",
        expect_paths=["absolute/rooted.txt"],
        expect_files={"absolute/rooted.txt": "rooted\n"},
    )
    z.write(p)

    # 13 — long CJK name
    long_name = "很长的文件名" * 12 + ".txt"
    z = RawZip()
    z.add(long_name, b"long\n", encoding="utf-8", utf8_flag=True)
    p = record(
        "13-long-name.zip",
        notes="~200-character UTF-8 filename.",
        expect_paths=[long_name],
        expect_files={long_name: "long\n"},
    )
    z.write(p)

    # 14 — many small files (filter / list)
    z = RawZip()
    for i in range(200):
        z.add(f"batch/item-{i:03d}.txt", f"{i}\n".encode(), encoding="utf-8", utf8_flag=True)
    p = record(
        "14-many-files.zip",
        notes="200 small files for listing and the filter field.",
        expect_paths=["batch/item-000.txt", "batch/item-199.txt"],
        expect_files={"batch/item-000.txt": "0\n"},
    )
    z.write(p)

    # 15 — nested archives (the new open-in-place feature)
    inner = RawZip()
    inner.add("hello.txt", b"nested-ok\n", encoding="utf-8", utf8_flag=True)
    inner_bytes = inner.dumps()

    mid = RawZip()
    mid.add("inner.zip", inner_bytes, encoding="utf-8", utf8_flag=True)
    mid.add("note.txt", b"mid\n", encoding="utf-8", utf8_flag=True)
    mid_bytes = mid.dumps()

    fake = b"this is not a zip, only named like one\n"

    jar = RawZip()
    jar.add("META-INF/MANIFEST.MF", b"Manifest-Version: 1.0\n", encoding="utf-8", utf8_flag=True)
    jar.add("com/example/A.class.txt", b"class\n", encoding="utf-8", utf8_flag=True)
    jar_bytes = jar.dumps()

    tar_buf = io.BytesIO()
    with tarfile.open(fileobj=tar_buf, mode="w") as tar:
        info = tarfile.TarInfo("from-tar.txt")
        payload = b"tar-payload\n"
        info.size = len(payload)
        tar.addfile(info, io.BytesIO(payload))
    import gzip

    tgz_buf = io.BytesIO()
    with gzip.GzipFile(fileobj=tgz_buf, mode="wb", filename="inner.tar") as gz:
        gz.write(tar_buf.getvalue())
    tgz_bytes = tgz_buf.getvalue()

    outer = RawZip()
    outer.add("inner.zip", inner_bytes, encoding="utf-8", utf8_flag=True)
    outer.add("mid.zip", mid_bytes, encoding="utf-8", utf8_flag=True)
    outer.add("bundle.tgz", tgz_bytes, encoding="utf-8", utf8_flag=True)
    outer.add("payload.jar", jar_bytes, encoding="utf-8", utf8_flag=True)
    outer.add("not-really.zip", fake, encoding="utf-8", utf8_flag=True)
    outer.add("readme.txt", b"open the real archives in-app\n", encoding="utf-8", utf8_flag=True)
    p = record(
        "15-nested.zip",
        notes="Zip-in-zip, zip-in-zip-in-zip, tgz, jar, and a fake .zip for fallback.",
        expect_paths=["inner.zip", "mid.zip", "bundle.tgz", "payload.jar", "not-really.zip", "readme.txt"],
        expect_files={"readme.txt": "open the real archives in-app\n"},
        nested=[
            {"path": "inner.zip", "expect_paths": ["hello.txt"], "expect_files": {"hello.txt": "nested-ok\n"}},
            {"path": "mid.zip", "expect_paths": ["inner.zip", "note.txt"]},
            {"path": "mid.zip", "then": "inner.zip", "expect_paths": ["hello.txt"]},
            {"path": "payload.jar", "expect_paths": ["META-INF/MANIFEST.MF", "com/example/A.class.txt"]},
        ],
        fake_archives=["not-really.zip"],
    )
    outer.write(p)

    # 16 — three-deep nest only
    deep_outer = RawZip()
    deep_outer.add("level1.zip", mid_bytes, encoding="utf-8", utf8_flag=True)
    p = record(
        "16-nested-deep.zip",
        notes="Three-deep nest: level1.zip → inner.zip → hello.txt.",
        expect_paths=["level1.zip"],
        nested=[
            {"path": "level1.zip", "expect_paths": ["inner.zip", "note.txt"]},
            {"path": "level1.zip", "then": "inner.zip", "expect_paths": ["hello.txt"], "expect_files": {"hello.txt": "nested-ok\n"}},
        ],
    )
    deep_outer.write(p)

    # 17 — UTF-8 outer wrapping a GBK inner (nested + encoding)
    gbk_inner = RawZip()
    gbk_inner.add("刷新目录", directory=True, encoding="gbk", utf8_flag=False)
    gbk_inner.add("刷新目录/内部说明.txt", "gbk-inside\n".encode(), encoding="gbk", utf8_flag=False)
    wrap = RawZip()
    wrap.add("legacy-inner.zip", gbk_inner.dumps(), encoding="utf-8", utf8_flag=True)
    wrap.add("outer.txt", b"wrapper\n", encoding="utf-8", utf8_flag=True)
    p = record(
        "17-nested-gbk.zip",
        notes="UTF-8 zip containing a GBK zip. Nested listing should still remap names.",
        expect_paths=["legacy-inner.zip", "outer.txt"],
        nested=[
            {
                "path": "legacy-inner.zip",
                "expect_paths": ["刷新目录", "刷新目录/内部说明.txt"],
                "expect_files": {"刷新目录/内部说明.txt": "gbk-inside\n"},
            }
        ],
    )
    wrap.write(p)

    # 18 — case twins (listing must show both; extract on APFS may collide)
    z = RawZip()
    z.add("Readme.txt", b"upper\n", encoding="utf-8", utf8_flag=True)
    z.add("readme.txt", b"lower\n", encoding="utf-8", utf8_flag=True)
    p = record(
        "18-duplicate-case.zip",
        notes="Readme.txt and readme.txt. List both; extract on APFS is allowed to collide.",
        expect_paths=["Readme.txt", "readme.txt"],
        skip_extract=True,
    )
    z.write(p)

    # 19 — tar
    tar_path = record(
        "19-formats.tar",
        notes="Plain tar with a folder and UTF-8 name.",
        expect_paths=["docs/hello.txt", "docs/中文.txt"],
        expect_files={"docs/hello.txt": "tar-hello\n", "docs/中文.txt": "tar-zh\n"},
    )
    make_tar(
        tar_path,
        [
            ("docs/hello.txt", b"tar-hello\n"),
            ("docs/中文.txt", "tar-zh\n".encode()),
        ],
    )

    # 20–22 — compressed tars
    compress_copy(tar_path, record(
        "20-formats.tgz",
        notes="gzip-wrapped tar. 7-Zip lists one member; double-click it to open the tar.",
        expect_file_count=1,
        nested=[{"index": 0, "expect_paths": ["docs/hello.txt", "docs/中文.txt"],
                 "expect_files": {"docs/hello.txt": "tar-hello\n"}}],
    ), "gz")
    compress_copy(tar_path, record(
        "21-formats.tar.bz2",
        notes="bzip2-wrapped tar. Double-click the inner tar.",
        expect_file_count=1,
        nested=[{"index": 0, "expect_paths": ["docs/hello.txt", "docs/中文.txt"],
                 "expect_files": {"docs/hello.txt": "tar-hello\n"}}],
    ), "bz2")
    compress_copy(tar_path, record(
        "22-formats.tar.xz",
        notes="xz-wrapped tar. Double-click the inner tar.",
        expect_file_count=1,
        nested=[{"index": 0, "expect_paths": ["docs/hello.txt", "docs/中文.txt"],
                 "expect_files": {"docs/hello.txt": "tar-hello\n"}}],
    ), "xz")

    # 23 — symlink tar
    p = record(
        "23-symlink.tar",
        notes="Regular file plus a symlink. Listing should show both.",
        expect_paths=["target.txt"],
        expect_files={"target.txt": "target\n"},
    )
    make_tar(p, [("target.txt", b"target\n")], symlink=("link-to-target", "target.txt"))

    if cli and lib and cli.exists() and lib.exists():
        staging = out_dir / ".staging"
        if staging.exists():
            shutil.rmtree(staging)
        staging.mkdir()

        a = staging / "alpha.txt"
        b = staging / "bravo.txt"
        c = staging / "charlie.txt"
        write_text(a, "alpha\n")
        write_text(b, "bravo\n")
        write_text(c, "charlie\n")

        cli_create(cli, lib, record(
            "24-plain.7z",
            notes="Ordinary 7z.",
            expect_paths=["alpha.txt", "bravo.txt", "charlie.txt"],
            expect_files={"alpha.txt": "alpha\n"},
        ), [a, b, c], solid=False)

        cli_create(cli, lib, record(
            "25-solid.7z",
            notes="Solid 7z. Packed size is only meaningful on the first file of a block.",
            expect_paths=["alpha.txt", "bravo.txt", "charlie.txt"],
            expect_files={"bravo.txt": "bravo\n"},
            solid=True,
        ), [a, b, c], solid=True)

        cli_create(cli, lib, record(
            "26-encrypted.zip",
            notes="Password-protected zip. Password: secret",
            password="secret",
            expect_paths=["alpha.txt"],
            expect_files={"alpha.txt": "alpha\n"},
        ), [a], password="secret")

        cli_create(cli, lib, record(
            "27-encrypted.7z",
            notes="Password-protected 7z (data only). Password: secret",
            password="secret",
            expect_paths=["alpha.txt", "bravo.txt"],
            expect_files={"alpha.txt": "alpha\n"},
        ), [a, b], password="secret")

        cli_create(cli, lib, record(
            "28-encrypted-headers.7z",
            notes="7z with encrypted headers. Listing without a password should fail. Password: secret",
            password="secret",
            encrypt_headers=True,
            expect_paths=["alpha.txt"],
            expect_files={"alpha.txt": "alpha\n"},
            require_password_to_list=True,
        ), [a], password="secret", encrypt_headers=True)

        cli_create(cli, lib, record(
            "29-wim.wim",
            notes="WIM container.",
            expect_paths=["alpha.txt", "bravo.txt"],
            expect_files={"alpha.txt": "alpha\n"},
        ), [a, b])

        # nest a 7z inside a zip
        seven = out_dir / "24-plain.7z"
        nest7 = RawZip()
        nest7.add("plain.7z", seven.read_bytes(), encoding="utf-8", utf8_flag=True)
        nest7.add("side.txt", b"side\n", encoding="utf-8", utf8_flag=True)
        nest7.write(record(
            "30-nested-7z.zip",
            notes="Zip containing a 7z. Double-click plain.7z should open in-app.",
            expect_paths=["plain.7z", "side.txt"],
            nested=[{"path": "plain.7z", "expect_paths": ["alpha.txt", "bravo.txt", "charlie.txt"]}],
        ))

        shutil.rmtree(staging)
    else:
        manifest["skipped_engine_formats"] = "rezipper-cli or 7z.so not found; 7z/wim/encrypted archives were not built"

    # Optional real-world sample already in Tests/
    history = ROOT / "01history.zip"
    if history.exists():
        manifest["archives"]["01history.zip"] = {
            "file": "01history.zip",
            "external": True,
            "notes": "Real Windows GBK zip. Folder entry uses a trailing slash; root used to list empty.",
            "expect_paths": ["0-1刷新"],
            "skip_extract": True,
        }

    (out_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT)
    parser.add_argument("--cli", type=Path, default=REPO / "build" / "rezipper-cli")
    parser.add_argument("--lib", type=Path, default=REPO / "build" / "ReZipper.app" / "Contents" / "Frameworks" / "7z.so")
    args = parser.parse_args()
    cli = args.cli if args.cli.exists() else None
    lib = args.lib if args.lib.exists() else None
    if not cli or not lib:
        print("warning: rezipper-cli/7z.so missing; generating zip/tar fixtures only", file=sys.stderr)
    manifest = generate(args.out, cli, lib)
    print(f"wrote {len(manifest['archives'])} archive entries to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
