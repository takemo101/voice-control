#!/bin/bash
# capture.sh が撮った動画・画像から、site/assets/ の動画（mp4・webm）・ポスター・画面の静止画を作る。
# 使い方：scripts/site/encode.sh [撮った場所]    撮った場所の既定：/tmp/vc-site-capture
# 切り出す範囲は、撮影の座標（Retina で 2 倍）に合わせてある：HUD は、画面の上の中央のパネルだけ（マウスのカーソルが入る下の部分は、切る）。
set -eu
IN=${1:-/tmp/vc-site-capture}
ASSETS=$(cd "$(dirname "$0")/../../site/assets" && pwd)
mkdir -p "$ASSETS/video" "$ASSETS/img"
q() { ffmpeg -v error -y "$@"; }
# 画面の上のパネル（録音 → 認識 → 実行中 → 確認 → 完了）
CROP_HUD="crop=1056:440:432:0,fps=30"
q -ss 0.9 -i "$IN/hud.mov" -t 16.5 -vf "$CROP_HUD" -c:v libx264 -preset slow -crf 27 -pix_fmt yuv420p -movflags +faststart -an "$ASSETS/video/demo-hud.mp4"
q -ss 0.9 -i "$IN/hud.mov" -t 16.5 -vf "$CROP_HUD" -c:v libvpx-vp9 -crf 38 -b:v 0 -pix_fmt yuv420p -an "$ASSETS/video/demo-hud.webm"
q -ss 2.9 -i "$IN/hud.mov" -frames:v 1 -vf "crop=1056:440:432:0" -q:v 3 "$ASSETS/video/demo-hud-poster.jpg"
# 各段階の静止画（動画の中の時刻。hud-preview は、1 段階 3 秒）
for pair in "recording:1.6" "thinking:4.4" "working:7.4" "confirm:10.4" "success:13.6"; do
  name=${pair%%:*}; t=${pair##*:}
  q -ss "$(python3 -c "print($t + 0.9)")" -i "$IN/hud.mov" -frames:v 1 -vf "crop=1056:420:432:0" "$ASSETS/img/hud-$name.png"
done
q -i "$IN/denied.png" -frames:v 1 -vf "crop=1056:420:432:0" "$ASSETS/img/hud-denied.png"
q -ss 14.5 -i "$IN/hud.mov" -frames:v 1 -vf "crop=1056:594:432:0,scale=1200:675,crop=1200:630:0:20" -q:v 3 "$ASSETS/og.jpg"
# Markdown のウィンドウ
CROP_WIN="crop=1400:1280:60:260,fps=30,scale=700:640"
q -ss 1.0 -i "$IN/window.mov" -t 4.5 -vf "$CROP_WIN" -c:v libx264 -preset slow -crf 27 -pix_fmt yuv420p -movflags +faststart -an "$ASSETS/video/demo-window.mp4"
q -ss 1.0 -i "$IN/window.mov" -t 4.5 -vf "$CROP_WIN" -c:v libvpx-vp9 -crf 38 -b:v 0 -pix_fmt yuv420p -an "$ASSETS/video/demo-window.webm"
q -ss 3 -i "$IN/window.mov" -frames:v 1 -q:v 3 "$ASSETS/video/demo-window-poster.jpg"
q -ss 3 -i "$IN/window.mov" -frames:v 1 -vf "crop=1400:1280:60:260" "$ASSETS/img/markdown-window.png"
echo "作った: $ASSETS"
