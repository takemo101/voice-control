#!/bin/bash
# build/release の vc を、開発用に BIN_DIR（既定 ~/.local/bin。管理者権限は不要）へ入れる。
# 実行ファイルは、コピーする（.build を消しても、動く）。
# モデルは、`vc model download` が ~/.voice-control/models/tiny-jev-0.6b に置く。このリポジトリの models/tiny-jev-0.6b（開発用）が
# すでにあり、~/.voice-control/models/tiny-jev-0.6b がなければ、複製せず、そこへのシンボリックリンクを張る（1.2 GB を取り直さない）。
# アクセシビリティ・マイクの許可は、変えない（vc を動かす端末アプリへの許可が要る。`agent-desktop permissions`）。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=.build/release/vc
[ -x "$SRC" ] || { echo "install.sh: $SRC がありません（先に just build）" >&2; exit 1; }

BIN="${BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN"
install -m 755 "$SRC" "$BIN/vc"
echo "installed: $BIN/vc"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "注: $BIN が PATH にありません。シェルの設定に足してください" >&2 ;; esac

MODEL="${MODEL_LINK:-$HOME/.voice-control/models/tiny-jev-0.6b}"
REPO_MODEL="$PWD/models/tiny-jev-0.6b"
# 以前の置き場所（~/Library/Application Support/voice-control/models）に、この script が張ったリンクがあれば、取り除く
LEGACY="$HOME/Library/Application Support/voice-control/models/tiny-jev-0.6b"
if [ -z "${MODEL_LINK:-}" ] && [ -L "$LEGACY" ]; then
    rm -f "$LEGACY"
    rmdir "$(dirname "$LEGACY")" "$(dirname "$(dirname "$LEGACY")")" 2>/dev/null || true
    echo "removed: ${LEGACY}（以前のリンク）"
fi
if [ -e "$MODEL" ] && [ ! -L "$MODEL" ]; then
    echo "モデル: 実体のディレクトリをそのまま使います: $MODEL"
elif [ -f "$REPO_MODEL/tokenizer.json" ] && [ -f "$REPO_MODEL/model.safetensors" ]; then
    mkdir -p "$(dirname "$MODEL")"
    ln -sfn "$REPO_MODEL" "$MODEL"
    echo "モデル: $MODEL -> $REPO_MODEL"
else
    echo "注: モデルがありません。vc model download で取得してください（~/.voice-control/models/tiny-jev-0.6b に置きます）" >&2
fi
echo "使い方: vc --help / vc run \"Safariを開いて\" --dry-run / vc listen --hotkey --execute（アクセシビリティ：agent-desktop permissions）"
