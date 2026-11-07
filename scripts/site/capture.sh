#!/bin/bash
# 製品ページ（site/）の動画・画像を、本物の vc の画面から撮る。
# 使い方：scripts/site/capture.sh <hud|window|denied|all> [出力先]    出力先の既定：/tmp/vc-site-capture
# 撮るもの：画面の上のパネル（vc hud-preview の作り物の内容）の動画と、Markdown のウィンドウ（vc show）の動画。
# **自作の背景ウィンドウ**（stage.swift：壁紙のような暗いグラデーション）の上で撮る。背景が出ていなければ撮らない（利用者の画面を、写さないため）。
# 画面収録の許可が要る。撮影中は、画面の上と中央に、背景と vc のウィンドウが出る（約 20 秒）。マウスのカーソルは、動画に入るので、あとの切り出し（encode.sh）で、範囲の外にする。
set -u
WHAT=${1:-all}
OUT=${2:-/tmp/vc-site-capture}
HERE=$(cd "$(dirname "$0")" && pwd)
VC=${VC:-$HERE/../../.build/release/vc}
mkdir -p "$OUT"
[ -x "$VC" ] || { echo "vc が見つかりません（just build）: $VC"; exit 1; }
swiftc -O "$HERE/stage.swift" -o "$OUT/stage" 2>&1 | grep -v "^$" | head -3

# 背景を出して、撮る範囲（左上が原点）を返す。出なければ、止まる
stage() { # <top|center> <幅> <高さ> <秒> <範囲のファイル>
  rm -f "$5"; "$OUT/stage" "$1" "$4" "$2" "$3" > "$5" &
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$5" ] && break; sleep 0.4; done
  if ! pgrep -x stage >/dev/null || [ ! -s "$5" ]; then echo "GUARD: 背景が出ていないので、撮りません"; pkill -x stage; exit 2; fi
}

hud() {
  stage top 960 540 45 "$OUT/region-hud.txt"
  screencapture -v -V 19 -x -R"$(cat "$OUT/region-hud.txt")" "$OUT/hud.mov" &
  REC=$!
  sleep 1.0
  NO_COLOR=1 "$VC" hud-preview --seconds 3 >/dev/null 2>&1 &
  sleep 0.8
  pgrep -f "vc hud-preview" >/dev/null || { echo "GUARD: hud-preview が動いていません"; kill $REC 2>/dev/null; pkill -x stage; exit 3; }
  wait $REC
  pkill -f "vc hud-preview"; pkill -x stage
  echo "撮った: $OUT/hud.mov"
}

denied() {
  stage top 960 540 20 "$OUT/region-denied.txt"
  NO_COLOR=1 "$VC" hud-preview --stage denied --seconds 15 >/dev/null 2>&1 &
  sleep 2.6
  pgrep -f "vc hud-preview" >/dev/null || { echo "GUARD: hud-preview が動いていません"; pkill -x stage; exit 3; }
  screencapture -x -R"$(cat "$OUT/region-denied.txt")" "$OUT/denied.png"
  pkill -f "vc hud-preview"; pkill -x stage
  echo "撮った: $OUT/denied.png"
}

window() {
  [ -f "$HERE/sample.md" ] || { echo "sample.md がありません"; exit 1; }
  stage center 760 900 45 "$OUT/region-window.txt"
  screencapture -v -V 7 -x -R"$(cat "$OUT/region-window.txt")" "$OUT/window.mov" &
  REC=$!
  sleep 1.2
  "$VC" show --file "$HERE/sample.md" --title "調べもの" --wait >/dev/null 2>&1 &
  sleep 1.5
  pgrep -f "vc show --file" >/dev/null || { echo "GUARD: vc show が動いていません"; kill $REC 2>/dev/null; pkill -x stage; exit 3; }
  wait $REC
  pkill -f "vc show --file"; pkill -x stage
  echo "撮った: $OUT/window.mov"
}

case "$WHAT" in
  hud) hud ;;
  window) window ;;
  denied) denied ;;
  all) hud; denied; window ;;
  *) echo "使い方: $0 <hud|window|denied|all> [出力先]"; exit 1 ;;
esac
