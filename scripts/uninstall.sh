#!/bin/bash
# install.sh で入れた vc と、モデルへのリンクを取り除く。
# 取り除くのは、BIN_DIR（既定 ~/.local/bin）の vc と、モデルのシンボリックリンクだけ。
# モデルの本体（リポジトリの models/）・実体のディレクトリ・アクセシビリティとマイクの許可には、触れない。
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="${BIN_DIR:-$HOME/.local/bin}"
if [ -e "$BIN/vc" ]; then rm -f "$BIN/vc"; echo "removed: $BIN/vc"; else echo "入っていません: $BIN/vc"; fi

SUPPORT="${MODEL_LINK:-$HOME/Library/Application Support/voice-control/models/tiny-jev-0.6b}"
if [ -L "$SUPPORT" ]; then
    rm -f "$SUPPORT"
    rmdir "$(dirname "$SUPPORT")" "$(dirname "$(dirname "$SUPPORT")")" 2>/dev/null || true
    echo "removed: $SUPPORT"
elif [ -e "$SUPPORT" ]; then
    echo "残しました（リンクではなく実体）: $SUPPORT"
fi
