#!/bin/bash
# build/VoiceControl.app を、開発用に、ユーザーのアプリケーションフォルダ（既定 ~/Applications。管理者権限は不要）へ入れる。
# 置き場所を変えるときは INSTALL_DIR を渡す（例: INSTALL_DIR=/Applications ./scripts/install.sh）。
# 同じ場所で実行中のアプリは、SIGTERM で終了させてから置き換える。入れたあと、アプリを起動する（起動したくないときは NO_OPEN=1）。
# RESET_PERMISSIONS=1 を渡すと、入れる前に、マイク・アクセシビリティ・画面収録の許可を取り消す（古い許可が残っていて、「許可されていません」と出るとき）。
# コマンド `vc` を、BIN_DIR（既定 ~/.local/bin）へ、シンボリックリンクで置く。INSTALL_DIR を変えているとき（検証用）は、BIN_DIR を渡さない限り、置かない。
# モデルは、設定ウィンドウ > モデル から取得する。このリポジトリの models/tiny-jev-0.6b（開発用）がすでにあり、~/.voice-control/models/tiny-jev-0.6b がなければ、
# 複製せず、そこへのシンボリックリンクを張る（1.2 GB を取り直さない）。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=build/VoiceControl.app
[ -d "$SRC" ] || { echo "install.sh: $SRC がありません（先に just app）" >&2; exit 1; }

# shellcheck source=scripts/install-lib.sh
. scripts/install-lib.sh
mkdir -p "${INSTALL_DIR:-$HOME/Applications}"
resolve_install_paths

stop_running_app || { echo "install.sh: 10 秒たっても終了しません（置き換えません）" >&2; exit 1; }

if [ -n "${RESET_PERMISSIONS:-}" ]; then reset_permissions; fi

rm -rf "$DEST"
ditto "$SRC" "$DEST"
codesign --verify --deep --strict "$DEST"
echo "installed: $DEST"

MODEL="${MODEL_LINK:-$HOME/.voice-control/models/tiny-jev-0.6b}"
REPO_MODEL="$PWD/models/tiny-jev-0.6b"
if [ -e "$MODEL" ] && [ ! -L "$MODEL" ]; then
    echo "モデル: 実体のディレクトリをそのまま使います: $MODEL"
elif [ -f "$REPO_MODEL/tokenizer.json" ] && [ -f "$REPO_MODEL/model.safetensors" ]; then
    mkdir -p "$(dirname "$MODEL")"
    ln -sfn "$REPO_MODEL" "$MODEL"
    echo "モデル: $MODEL -> $REPO_MODEL"
else
    echo "注: モデルがありません。アプリの設定 > モデル で取得してください（~/.voice-control/models/tiny-jev-0.6b に置きます）" >&2
fi

if [ -z "${NO_OPEN:-}" ]; then
    open "$DEST"
    for _ in $(seq 1 50); do
        [ -n "$(running_pids)" ] && break
        sleep 0.1
    done
    if [ -n "$(running_pids)" ]; then echo "起動しました（メニューバーのマイクのアイコン）"
    else echo "install.sh: 起動を確認できませんでした（open \"$DEST\" で起動してください）" >&2; exit 1; fi
fi

if [ -z "${INSTALL_DIR:-}" ] || [ -n "${BIN_DIR:-}" ]; then
    BIN="${BIN_DIR:-$HOME/.local/bin}"
    mkdir -p "$BIN"
    if [ -e "$BIN/vc" ] && [ ! -L "$BIN/vc" ]; then
        echo "注: $BIN/vc に、リンクではないファイルがあります（以前の tar.gz 版など）。置き換えません。消してから、もう一度実行してください" >&2
    else
        ln -sfn "$EXE" "$BIN/vc"
        echo "コマンド:  $BIN/vc → $EXE（スキルが使うコマンド。vc --help）"
    fi
    case ":$PATH:" in *":$BIN:"*) ;; *) echo "注: $BIN が PATH にありません。シェルの設定に足してください" >&2 ;; esac
fi
echo "注: ad-hoc 署名でも、指定要件を bundle ID だけにしてあるので、入れ直しても、許可は残る見込み（未確認）。外れたら RESET_PERMISSIONS=1"
