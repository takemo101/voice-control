#!/bin/bash
# build/release の vc を、開発用に BIN_DIR（既定 ~/.local/bin。管理者権限は不要）へ入れる。
# 実行ファイルは、コピーする（.build を消しても、動く）。
# モデルは、複製しない：~/Library/Application Support/voice-control/models/tiny-jev-0.6b を、このリポジトリの models/tiny-jev-0.6b へのシンボリックリンクにする
# （すでに実体のディレクトリがあれば、そのまま使う）。models/ が無ければ、先に `just fetch-model`。
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

SUPPORT="${MODEL_LINK:-$HOME/Library/Application Support/voice-control/models/tiny-jev-0.6b}"
REPO_MODEL="$PWD/models/tiny-jev-0.6b"
if [ -e "$SUPPORT" ] && [ ! -L "$SUPPORT" ]; then
    echo "モデル: 実体のディレクトリをそのまま使います: $SUPPORT"
elif [ -f "$REPO_MODEL/tokenizer.json" ] && [ -f "$REPO_MODEL/model.safetensors" ]; then
    mkdir -p "$(dirname "$SUPPORT")"
    ln -sfn "$REPO_MODEL" "$SUPPORT"
    echo "モデル: $SUPPORT -> $REPO_MODEL"
else
    echo "注: モデルがありません。just fetch-model のあと、もう一度 just install（または、MODEL_DIR を指定して scripts/fetch-model.sh）" >&2
fi
echo "使い方: vc plan \"下にスクロールして\" / vc listen --execute（アクセシビリティ：agent-desktop permissions）"
