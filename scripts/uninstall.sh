#!/bin/bash
# install.sh で入れた vc と、モデルへのリンクを取り除く。
# 取り除くのは、BIN_DIR（既定 ~/.local/bin）の vc と、モデルのシンボリックリンク（~/.voice-control/models/tiny-jev-0.6b）だけ。
# モデルの本体（リポジトリの models/・vc model download で置いた実体のディレクトリ）・スキル・設定・アクセシビリティとマイクの許可には、触れない。
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="${BIN_DIR:-$HOME/.local/bin}"
if [ -e "$BIN/vc" ]; then rm -f "$BIN/vc"; echo "removed: $BIN/vc"; else echo "入っていません: $BIN/vc"; fi

MODEL="${MODEL_LINK:-$HOME/.voice-control/models/tiny-jev-0.6b}"
if [ -L "$MODEL" ]; then
    rm -f "$MODEL"
    rmdir "$(dirname "$MODEL")" 2>/dev/null || true
    echo "removed: $MODEL"
elif [ -e "$MODEL" ]; then
    echo "残しました（リンクではなく実体）: $MODEL"
fi
