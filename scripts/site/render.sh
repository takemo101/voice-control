#!/bin/bash
# 設定ウィンドウと会話のウィンドウを、**画面に出さずに**（画面の外で）描いて、README・docs・製品ページの画像と動画を作る。
# 使い方：scripts/site/render.sh [作業フォルダ]    作業フォルダの既定：/tmp/vc-site-render
# 画面収録の許可は、要らない。利用者の画面・アプリは、写らない（自作の見本の内容だけ）。ffmpeg が要る。
# 描くのは、本物の SwiftUI の画面（`vc settings-preview`・`vc chat-preview --frames`）。ガラスの透け感は描けないので、会話のウィンドウは、不透明の背景になる
# （ガラスの見た目は、`scripts/site/capture.sh chat` で、画面収録の許可があるときに、撮れる）。
# 見本の環境：見本のホーム（スキルは、リポジトリの `.voice-control/skills`）と、`HOME` を仮のものにして、利用者のパス・設定・スキルが、画像に入らないようにする。
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
VC=${VC:-$ROOT/.build/release/vc}
WORK=${1:-/tmp/vc-site-render}
ICON=${ICON:-$ROOT/build/VoiceControl.app/Contents/Resources/AppIcon.icns}
[ -x "$VC" ] || { echo "vc が見つかりません（just build）: $VC"; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg が要ります"; exit 1; }
rm -rf "$WORK"; mkdir -p "$WORK/home/skills" "$WORK/settings" "$WORK/frames"
cp -R "$ROOT/.voice-control/skills/." "$WORK/home/skills/"
[ -d "$HOME/.voice-control/models" ] && ln -s "$HOME/.voice-control/models" "$WORK/home/models"   # モデルの有無の表示だけ（読むだけ）
echo '{"chatTools":"read"}' > "$WORK/home/settings.json"
export HOME=/Users/user VC_HOME="$WORK/home"
ICON_ARGS=(); [ -f "$ICON" ] && ICON_ARGS=(--icon "$ICON")
cd "$WORK"
"$VC" settings-preview "$WORK/settings" "${ICON_ARGS[@]}" >/dev/null
"$VC" chat-preview --frames "$WORK/frames" --fps 10 >/dev/null
q() { ffmpeg -v error -y "$@"; }
DOCS="$ROOT/docs/images"; SITE="$ROOT/site/assets"
mkdir -p "$DOCS" "$SITE/img" "$SITE/video"
# 設定の各ページ（幅 1200）
for page in general keys voice chat models skills; do
  for dest in "$DOCS" "$SITE/img"; do q -i "$WORK/settings/settings-$page.png" -vf "scale=1200:-1:flags=lanczos" "$dest/settings-$page.png"; done
done
# 会話のウィンドウの静止画（動画の中の時刻。10 枚 / 秒）：声を聞く案内・調べて答える・外のエージェント・画像つきの質問
for pair in "listening:20" "answer:110" "files:215" "image:300"; do
  name=${pair%%:*}; n=${pair##*:}
  for dest in "$DOCS" "$SITE/img"; do q -i "$WORK/frames/$(printf 'frame-%04d.png' "$n")" -vf "scale=800:-1:flags=lanczos" "$dest/chat-$name.png"; done
done
# 会話の動画（mp4・webm・ポスター）。最後の画面を、1.5 秒、止める
VF="scale=640:-2:flags=lanczos,tpad=stop_mode=clone:stop_duration=1.5"
q -framerate 10 -i "$WORK/frames/frame-%04d.png" -vf "$VF" -c:v libx264 -preset slow -crf 26 -pix_fmt yuv420p -movflags +faststart -an "$SITE/video/demo-chat.mp4"
q -framerate 10 -i "$WORK/frames/frame-%04d.png" -vf "$VF" -c:v libvpx-vp9 -crf 38 -b:v 0 -pix_fmt yuv420p -an "$SITE/video/demo-chat.webm"
q -i "$WORK/frames/frame-0110.png" -vf "scale=640:-2:flags=lanczos" -frames:v 1 -q:v 3 "$SITE/video/demo-chat-poster.jpg"
echo "作った: ${DOCS}・${SITE}"
