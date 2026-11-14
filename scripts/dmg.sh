#!/bin/bash
# dist/vc-<版>-macos-arm64.dmg と SHA-256 を作る（VoiceControl.app と /Applications へのショートカット入り。Apple silicon。ad-hoc 署名）。
# 署名は ad-hoc のまま（Developer ID の署名・公証はしない）。他の Mac で開くと、Gatekeeper の警告が出る：`xattr -dr com.apple.quarantine /Applications/VoiceControl.app`。
# NAME_SUFFIX を渡すと、ファイル名の版のあとに足す（ドライラン用：例 -dev-abc1234）。
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

APP=build/VoiceControl.app
VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
NAME="vc-${VERSION}${NAME_SUFFIX:-}-macos-arm64"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p dist
rm -f "dist/${NAME}.dmg" "dist/${NAME}.dmg.sha256"

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname VoiceControl -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "dist/${NAME}.dmg"
(cd dist && shasum -a 256 "${NAME}.dmg" > "${NAME}.dmg.sha256")
echo "version=${VERSION}"
echo "asset=${NAME}.dmg"
cat "dist/${NAME}.dmg.sha256"
