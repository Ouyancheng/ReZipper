# License

ReZipper’s own source (`App/`, `Engine/`, `Resources/`, `scripts/`, and this
documentation) is released under the MIT License.

The app **loads** the official 7-Zip library (`7z.so`) and **links** bit7z.
Those components keep their own licenses. Shipping a ReZipper binary means you
must also follow the 7-Zip and bit7z terms below.

---

## ReZipper (MIT)

Copyright (c) 2026 Yancheng Ou and Cursor Grok 4.6

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the “Software”), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Third-party

### 7-Zip 26.02 — GNU LGPL 2.1 (or later), with unRAR restriction

Copyright (C) 1999–2026 Igor Pavlov.

`7z.so` (Format7zF) is built from `ThirdParty/7zip` and bundled at
`ReZipper.app/Contents/Frameworks/7z.so`. It is a **separate shared library**.
You may replace that file with another compatible 7-Zip build.

Most 7-Zip sources are GNU LGPL 2.1 or later. RAR decompression also carries
Alexander Roshal’s **unRAR restriction**: those sources must not be used to
re-create the proprietary RAR *compression* algorithm.

Full text: [`ThirdParty/7zip/DOC/License.txt`](ThirdParty/7zip/DOC/License.txt)

Some 7-Zip files use BSD-2/BSD-3 (LZFSE, Zstd, XXH64). Those notices are in
the same file.

### bit7z — Mozilla Public License 2.0

Copyright (c) Riccardo Ostani.

bit7z is used as a C++ wrapper around 7-Zip. MPL 2.0 is file-level copyleft:
modifications to bit7z files must stay under MPL 2.0.

Full text: [`ThirdParty/bit7z/LICENSE`](ThirdParty/bit7z/LICENSE)
