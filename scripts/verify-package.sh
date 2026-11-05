#!/bin/bash
# package.sh が作った tar.gz を、展開して検査する：SHA-256・中身・アーキテクチャ・署名・実際に動くか（モデル・Apple Intelligence は使わないコマンドだけ）。
# 使い方：scripts/verify-package.sh dist/vc-0.1.0-macos-arm64.tar.gz 0.1.0
set -euo pipefail
cd "$(dirname "$0")/.."
ARCHIVE="${1:?tar.gz のパス}"
VERSION="${2:?期待する版}"

(cd "$(dirname "$ARCHIVE")" && shasum -a 256 -c "$(basename "$ARCHIVE").sha256")
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -xzf "$ARCHIVE" -C "$WORK"
DIR="$(echo "$WORK"/vc-*)"

for f in vc LICENSE THIRD_PARTY_NOTICES.md README.md skills/voice-control-skill-author/SKILL.md; do
    [ -e "$DIR/$f" ] || { echo "verify-package: $f がありません" >&2; exit 1; }
done
file "$DIR/vc" | grep -q "arm64" || { echo "verify-package: arm64 ではありません" >&2; file "$DIR/vc" >&2; exit 1; }
codesign --verify --strict "$DIR/vc"
# 動的リンクは、OS の標準の場所だけ（同梱していないライブラリに依存していないこと）
if otool -L "$DIR/vc" | tail -n +2 | awk '{print $1}' | grep -v -E '^(/usr/lib/|/System/Library/)'; then
    echo "verify-package: OS 標準以外のライブラリに依存しています" >&2
    exit 1
fi
[ "$("$DIR/vc" --version)" = "vc ${VERSION}" ] || { echo "verify-package: vc --version が vc ${VERSION} ではありません" >&2; exit 1; }
"$DIR/vc" --help > /dev/null
"$DIR/vc" run --help > /dev/null
# モデルがなくても動くこと（空の VC_HOME で、スキルの一覧・モデルの状態・ホットキーの設定）
VC_HOME="$WORK/home" "$DIR/vc" skills > /dev/null
VC_HOME="$WORK/home" "$DIR/vc" model status > /dev/null
VC_HOME="$WORK/home" "$DIR/vc" hotkey set ctrl+opt+space > /dev/null
[ "$(VC_HOME="$WORK/home" "$DIR/vc" hotkey | grep -c "ctrl+opt+space")" -ge 1 ] || { echo "verify-package: vc hotkey が、設定を返しません" >&2; exit 1; }
echo "verify-package: OK (${VERSION})"
