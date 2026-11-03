#!/bin/bash
# vc をリリースビルドして、配布用の tar.gz と SHA-256 を dist/ に作る（リリースのワークフローと同じ手順）。
#   dist/vc-<版>-macos-arm64.tar.gz       中身：vc・LICENSE・README.md・scripts/fetch-model.sh・skills/voice-control-skill-author/
#   dist/vc-<版>-macos-arm64.tar.gz.sha256
# 版は、ビルドした vc の `--version`（Sources/vc/Version.swift）。NAME_SUFFIX を渡すと、ファイル名の版のあとに足す（ドライラン用：例 -dev-abc1234）。
# 署名は ad-hoc（SwiftPM が付ける）。署名・公証の鍵や認証情報は、使わない。
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product vc 2>&1 | { grep -v "ld: warning: search path .*/CommandLineTools/Developer" || true; }
BIN=.build/release/vc
VERSION="$("$BIN" --version | awk '{print $2}')"
[ -n "$VERSION" ] || { echo "package.sh: vc --version を読めません" >&2; exit 1; }

NAME="vc-${VERSION}${NAME_SUFFIX:-}-macos-arm64"
STAGE="dist/${NAME}"
rm -rf dist
mkdir -p "$STAGE/scripts" "$STAGE/skills"
install -m 755 "$BIN" "$STAGE/vc"
cp LICENSE README.md "$STAGE/"
install -m 755 scripts/fetch-model.sh "$STAGE/scripts/fetch-model.sh"
cp -R skills/voice-control-skill-author "$STAGE/skills/"

tar -C dist -czf "dist/${NAME}.tar.gz" "${NAME}"
rm -rf "$STAGE"
(cd dist && shasum -a 256 "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256")
echo "version=${VERSION}"
echo "asset=${NAME}.tar.gz"
cat "dist/${NAME}.tar.gz.sha256"
