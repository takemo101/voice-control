# 第三者のソフトウェアとモデルの表示

`vc` は、次を、静的ライブラリ（音声認識の推論の実行環境）として含みます。ダウンロードして使う音声認識のモデルは、利用者が `vc model download` で取得したときだけ使います（リポジトリ・配布物には含めません）。

| もの | ライセンス | 入手先・版 |
|---|---|---|
| transcribe.cpp（推論の実行環境。ggml・Silero VAD・miniz を含む） | MIT | https://github.com/handy-computer/transcribe.cpp ・ commit `5700f127e38dd53c4735ea23ef743b4b538eacd4`（`scripts/build-native.sh` が、この版を、ビルドして取り込む） |
| Whisper large-v3-turbo（音声認識のモデル。任意の取得） | MIT（OpenAI） | `handy-computer/whisper-large-v3-turbo-gguf`（GGUF〔Q8_0〕へ変換したもの）・版は `Sources/VCSpeech/SpeechModelCatalog.swift` に固定 |

## transcribe.cpp

```
MIT License

Copyright (c) 2026 The transcribe.cpp authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 取り込まれている部品（transcribe.cpp の THIRD-PARTY-LICENSES.md から）
--------|---------|-------------|-----|
| ggml      | MIT     | [`ggml/LICENSE`](ggml/LICENSE) | see [`ggml/UPSTREAM`](ggml/UPSTREAM) |
| Silero VAD | MIT | [`src/third_party/silero_vad/LICENSE`](src/third_party/silero_vad/LICENSE) | see [`src/third_party/silero_vad/UPSTREAM`](src/third_party/silero_vad/UPSTREAM) |
| miniz     | MIT     | [`src/third_party/miniz/LICENSE`](src/third_party/miniz/LICENSE) | see [`src/third_party/miniz/UPSTREAM`](src/third_party/miniz/UPSTREAM) |

Prebuilt artifacts (the Swift xcframework, the native Python wheels, and the
npm platform packages) carry these same texts alongside the binaries — see each
binding's packaging for the bundled `LICENSE.ggml` / `LICENSE.miniz` / `LICENSE.silero_vad` files.

Conversion-time tooling also includes `scripts/lib/phonon.py`, adapted from
Fermion Research's Apache-2.0 container reader at
`FermionResearch/Phonon-2@7e153e4054c0a10db6d47d6fff5c062d4c77c154`.
Copyright 2026 Fermion Research. Modifications add strict record validation,
pinned artifact handling and F32 conversion. Its license text is
[`scripts/lib/phonon-LICENSE-Apache-2.0.txt`](scripts/lib/phonon-LICENSE-Apache-2.0.txt).
It is not linked into native binaries. Model-weight attribution and licenses
are separate; see [`docs/models/phonon-2.md`](docs/models/phonon-2.md).

---

## ggml

The tensor library underlying transcribe.cpp. Vendored under `ggml/`.

```
MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## miniz

A single-file deflate/inflate (zlib-subset) codec. transcribe.cpp uses it only
for Whisper's temperature-fallback compression-ratio heuristic; it replaces the
previous system-zlib dependency. Vendored under `src/third_party/miniz/`.

miniz is MIT-licensed. (The comment block at the top of the amalgamated
`miniz.c` / `miniz.h` still reads "public domain" — a stale artifact from the
project's pre-relicensing history; upstream's current and authoritative license
is the MIT text below, also shipped at `src/third_party/miniz/LICENSE`.)

```
Copyright 2013-2014 RAD Game Tools and Valve Software
Copyright 2010-2014 Rich Geldreich and Tenacious Software LLC

All Rights Reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

---

## Silero VAD

The offline segmentation in `src/transcribe-vad.cpp` is
translated from `silero_vad/utils_vad.py`, pinned to silero-vad 6.2.3. The
authoritative text is `src/third_party/silero_vad/LICENSE`; native artifacts
include it as `LICENSE.silero_vad`.

```
MIT License

Copyright (c) 2020-present Silero Team

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
