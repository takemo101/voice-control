#!/bin/bash
# capture.sh が撮った動画・画像から、site/assets/ の動画（mp4・webm）・ポスター・画面の静止画を作る。
# 使い方：scripts/site/encode.sh [撮った場所]    撮った場所の既定：/tmp/vc-site-capture
# 会話のウィンドウの動画・静止画も、ここで作る。切り出す範囲は、撮影の座標（Retina で 2 倍）に合わせてある：HUD は、画面の上の中央のパネルだけ（マウスのカーソルが入る下の部分は、切る）。
set -eu
IN=${1:-/tmp/vc-site-capture}
ASSETS=$(cd "$(dirname "$0")/../../site/assets" && pwd)
mkdir -p "$ASSETS/video" "$ASSETS/img"
q() { ffmpeg -v error -y "$@"; }
# 画面の上のパネル（録音 → 録音中の文字 → 認識 → 実行中 → 確認 → 完了。capture.sh が、1 段階 3 秒で出す）
CROP_HUD="crop=1056:440:432:0,fps=30"
q -ss 0.9 -i "$IN/hud.mov" -t 20 -vf "$CROP_HUD" -c:v libx264 -preset slow -crf 27 -pix_fmt yuv420p -movflags +faststart -an "$ASSETS/video/demo-hud.mp4"
q -ss 0.9 -i "$IN/hud.mov" -t 20 -vf "$CROP_HUD" -c:v libvpx-vp9 -crf 38 -b:v 0 -pix_fmt yuv420p -an "$ASSETS/video/demo-hud.webm"
q -ss 2.9 -i "$IN/hud.mov" -frames:v 1 -vf "crop=1056:440:432:0" -q:v 3 "$ASSETS/video/demo-hud-poster.jpg"
# 各段階の静止画（動画の中の時刻。1 段階 3 秒）
for pair in "recording:1.6" "caption:5.4" "thinking:7.4" "working:10.4" "confirm:13.4" "success:18.0"; do
  name=${pair%%:*}; t=${pair##*:}
  q -ss "$(python3 -c "print($t + 0.9)")" -i "$IN/hud.mov" -frames:v 1 -vf "crop=1056:420:432:0" "$ASSETS/img/hud-$name.png"
done
q -i "$IN/denied.png" -frames:v 1 -vf "crop=1056:420:432:0" "$ASSETS/img/hud-denied.png"
q -ss 18.9 -i "$IN/hud.mov" -frames:v 1 -vf "crop=1056:594:432:0,scale=1200:675,crop=1200:630:0:20" -q:v 3 "$ASSETS/og.jpg"
# Markdown のウィンドウ
CROP_WIN="crop=1400:1280:60:260,fps=30,scale=700:640"
q -ss 1.0 -i "$IN/window.mov" -t 4.5 -vf "$CROP_WIN" -c:v libx264 -preset slow -crf 27 -pix_fmt yuv420p -movflags +faststart -an "$ASSETS/video/demo-window.mp4"
q -ss 1.0 -i "$IN/window.mov" -t 4.5 -vf "$CROP_WIN" -c:v libvpx-vp9 -crf 38 -b:v 0 -pix_fmt yuv420p -an "$ASSETS/video/demo-window.webm"
q -ss 3 -i "$IN/window.mov" -frames:v 1 -q:v 3 "$ASSETS/video/demo-window-poster.jpg"
q -ss 3 -i "$IN/window.mov" -frames:v 1 -vf "crop=1400:1280:60:260" "$ASSETS/img/markdown-window.png"
# 会話のウィンドウ（capture.sh chat。録画は 1520×1800：背景の範囲の全体を使う。出来事は、録画の約 2.1 秒後に始まる）
CROP_CHAT="crop=1440:1680:40:60,fps=30,scale=720:840"
q -ss 1.5 -i "$IN/chat.mov" -t 34 -vf "$CROP_CHAT" -c:v libx264 -preset slow -crf 27 -pix_fmt yuv420p -movflags +faststart -an "$ASSETS/video/demo-chat.mp4"
q -ss 1.5 -i "$IN/chat.mov" -t 34 -vf "$CROP_CHAT" -c:v libvpx-vp9 -crf 38 -b:v 0 -pix_fmt yuv420p -an "$ASSETS/video/demo-chat.webm"
q -ss 13 -i "$IN/chat.mov" -frames:v 1 -vf "crop=1440:1680:40:60,scale=720:840" -q:v 3 "$ASSETS/video/demo-chat-poster.jpg"
DOCS="$(cd "$(dirname "$0")/../.." && pwd)/docs/images"
for pair in "listening:4.4" "answer:13" "files:23.5" "image:32.5"; do
  name=${pair%%:*}; t=${pair##*:}
  q -ss "$t" -i "$IN/chat.mov" -frames:v 1 -vf "crop=1440:1680:40:60,scale=800:-1" "$ASSETS/img/chat-$name.png"
  cp "$ASSETS/img/chat-$name.png" "$DOCS/chat-$name.png"
done
for name in hud-recording hud-caption hud-thinking hud-working hud-confirm hud-success hud-denied markdown-window; do cp "$ASSETS/img/$name.png" "$DOCS/$name.png"; done   # README 用の複製
echo "作った: ${ASSETS}・${DOCS}"
