#!/bin/bash
# build/VoiceControl.app を作る（Apple silicon。ad-hoc 署名）。
# アプリの中の実行ファイル（Contents/MacOS/vc）は、CLI の `vc` と同じもの：引数なしで起動すると、メニューバーのアプリ・引数があれば、CLI（スキルが使うコマンド）。
#
#   ./scripts/build-app.sh
#   NAME_SUFFIX は使わない（dmg.sh のドライラン用の名前は、dmg の名前だけ）
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-native.sh   # 音声認識の実行環境（transcribe.cpp。ビルド済みなら、何もしない）
swift build -c release --explicit-target-dependency-import-check=error --product vc 2>&1 | { grep -v "ld: warning: search path .*/CommandLineTools/Developer" || true; }
BIN=.build/release/vc
VERSION="$("$BIN" --version | awk '{print $2}')"
[ -n "$VERSION" ] || { echo "build-app.sh: vc --version を読めません" >&2; exit 1; }

APP=build/VoiceControl.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/skills"
install -m 755 "$BIN" "$APP/Contents/MacOS/vc"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
# アプリのアイコン（scripts/make-icon.sh で生成してコミットしたもの）
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
# スキルを作る・直すためのスキル（エージェントの skill フォルダへ、コピーして使う）
cp -R skills/voice-control-skill-author "$APP/Contents/Resources/skills/"
# ACP アダプターの固定ファイル（package.json・package-lock.json。アダプター本体は、同梱しない：利用者が選んだときだけ、アプリが入れる）
mkdir -p "$APP/Contents/Resources/adapters"
for adapter in adapters/*/; do
  name="$(basename "$adapter")"
  mkdir -p "$APP/Contents/Resources/adapters/$name"
  cp "$adapter/package.json" "$adapter/package-lock.json" "$APP/Contents/Resources/adapters/$name/"
done

# 署名は ad-hoc（鍵・認証情報は、使わない）。ad-hoc 署名は、既定では、署名の識別（指定要件）が実行ファイルのハッシュ（cdhash）になり、ビルドのたびに変わる。
# マイク・アクセシビリティの許可は、この要件に紐づくので、更新のたびに、設定ではオンに見えても、無効になる。
# そこで、指定要件を bundle ID だけにして、版が変わっても、同じアプリとして扱われるようにする（meeting-analyzer と同じ方式。この Mac で、更新後も許可が残ることは、**未確認**）。
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
codesign --force --sign - -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
codesign --verify --strict "$APP"

echo "built: $APP"
lipo -archs "$APP/Contents/MacOS/vc"
