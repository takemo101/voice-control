#!/bin/bash
# 設定ウィンドウを、**画面に出さずに**（画面の外で）描いて、README・docs・製品ページの画像を作る。
# 使い方：scripts/site/render.sh [作業フォルダ]    作業フォルダの既定：/tmp/vc-site-render
# 画面収録の許可は、要らない。利用者の画面・アプリは、写らない（自作の見本の内容だけ）。ffmpeg が要る。
# 描くのは、本物の SwiftUI の画面（`vc settings-preview`）。会話・パネル・Markdown のウィンドウは、`scripts/site/capture.sh`（画面収録の許可が要る）。
# 見本の環境：見本のホーム（スキルは、リポジトリの `.voice-control/skills`）と、`HOME` を仮のものにして、利用者のパス・設定・スキルが、画像に入らないようにする。
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
VC=${VC:-$ROOT/.build/release/vc}
WORK=${1:-/tmp/vc-site-render}
ICON=${ICON:-$ROOT/Resources/AppIcon.icns}   # 生成物（リポジトリにある）：build/ のアプリの、古いアイコンを、使わない
[ -x "$VC" ] || { echo "vc が見つかりません（just build）: $VC"; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg が要ります"; exit 1; }
rm -rf "$WORK"; mkdir -p "$WORK/home/skills" "$WORK/settings"
cp -R "$ROOT/.voice-control/skills/." "$WORK/home/skills/"
[ -d "$HOME/.voice-control/models" ] && ln -s "$HOME/.voice-control/models" "$WORK/home/models"   # モデルの有無の表示だけ（読むだけ）
echo '{"chatTools":"read"}' > "$WORK/home/settings.json"
export HOME=/Users/user VC_HOME="$WORK/home"
ICON_ARGS=(); [ -f "$ICON" ] && ICON_ARGS=(--icon "$ICON")
cd "$WORK"
"$VC" settings-preview "$WORK/settings" "${ICON_ARGS[@]}" >/dev/null
q() { ffmpeg -v error -y "$@"; }
DOCS="$ROOT/docs/images"; SITE="$ROOT/site/assets"
mkdir -p "$DOCS" "$SITE/img"
# 設定の各ページ（幅 1200）
for page in general keys voice dictation chat models skills; do
  for dest in "$DOCS" "$SITE/img"; do q -i "$WORK/settings/settings-$page.png" -vf "scale=1200:-1:flags=lanczos" "$dest/settings-$page.png"; done
done
# 会話のウィンドウ：考えている間の順番待ち（本物の SwiftUI の画面を、画面の外で描く。幅 720）
"$VC" settings-preview "$WORK/chat" --chat >/dev/null
for dest in "$DOCS" "$SITE/img"; do q -i "$WORK/chat/chat-pending.png" -vf "scale=720:-1:flags=lanczos" "$dest/chat-queue.png"; done
echo "作った: ${DOCS}・${SITE}"
