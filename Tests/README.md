# Stress archives

Hand-check these in `ReZipper.app`, or run them through the engine:

```bash
python3 Tests/generate_stress.py
python3 Tests/run_stress.py
```

`01history.zip` is a real Windows zip (GBK names, `folder/` directory entries). It is not regenerated. Everything else is built by `generate_stress.py` and kept small.

Password for the encrypted fixtures: `secret`.

| Archive | What it stresses |
| --- | --- |
| `01history.zip` | Real GBK zip. Trailing-slash folder used to make the root list empty. |
| `02-gbk-folders.zip` | Same class as 01, tiny: GBK + explicit `刷新/` entry. |
| `03-gbk-implicit.zip` | GBK files with parent paths but no directory entries. |
| `04-shiftjis.zip` | Japanese names, no UTF-8 flag. |
| `05-big5.zip` | Traditional Chinese names, no UTF-8 flag. |
| `06-euckr.zip` | Korean names, no UTF-8 flag. |
| `07-utf8-flag.zip` | Control: UTF-8 flag set, including emoji. |
| `08-special-names.zip` | Spaces, dots, `#`, `%`, brackets, quotes, `café`. |
| `09-empty-zero.zip` | Empty folders and a zero-byte file. |
| `10-deep-tree.zip` | 12-level path plus root siblings (sidebar / path bar). |
| `11-windows-backslash.zip` | `win\folder\readme.txt` must show as `win/folder/…`. |
| `12-absolute-path.zip` | Leading `/` must be stripped. |
| `13-long-name.zip` | Very long CJK filename. |
| `14-many-files.zip` | 200 files for listing and Filter. |
| `15-nested.zip` | Zip-in-zip, mid→inner, `.tgz`, `.jar`, and a fake `.zip`. |
| `16-nested-deep.zip` | Three-deep peel. |
| `17-nested-gbk.zip` | UTF-8 wrapper around a GBK zip. |
| `18-duplicate-case.zip` | `Readme.txt` and `readme.txt` both listed. |
| `19-formats.tar` | Plain tar, UTF-8 names. |
| `20-formats.tgz` | gzip(tar). Double-click the inner member to open the tar. |
| `21-formats.tar.bz2` | bzip2(tar). |
| `22-formats.tar.xz` | xz(tar). |
| `23-symlink.tar` | File + symlink. |
| `24-plain.7z` | Ordinary 7z. |
| `25-solid.7z` | Solid 7z packed-size display. |
| `26-encrypted.zip` | Zip password. |
| `27-encrypted.7z` | 7z password. |
| `28-encrypted-headers.7z` | Header encryption; listing needs the password. |
| `29-wim.wim` | WIM. |
| `30-nested-7z.zip` | Zip containing a 7z. |

In the app, double-click a nested archive (`.zip`, `.7z`, `.tgz`, `.jar`, …) to open it in a new window. `not-really.zip` should fall back to extract-and-open.
