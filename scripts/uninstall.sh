#!/bin/bash
# install.sh で入れたアプリとコマンドを、取り除く。
# 入れ先は INSTALL_DIR（既定 ~/Applications）、コマンドの置き場所は BIN_DIR（既定 ~/.local/bin。INSTALL_DIR を変えているときは、BIN_DIR を渡したときだけ）。
# 取り除くのは、アプリ本体と、そのアプリを指すコマンドのシンボリックリンクと、モデルのシンボリックリンク（~/.voice-control/models/tiny-jev-0.6b）だけ。
# 既定の場所（INSTALL_DIR を変えていないとき）では、アプリの削除の前に、マイク・アクセシビリティ・画面収録の許可も取り消す（`tccutil reset`）。
# 許可は bundle ID に紐づくので、INSTALL_DIR を変えた検証用のコピーでは、RESET_PERMISSIONS=1 を渡したときだけ取り消す。
# モデルの本体・スキル・設定には、触れない。
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=scripts/install-lib.sh
. scripts/install-lib.sh
resolve_install_paths

stop_running_app || { echo "uninstall.sh: 10 秒たっても終了しません（取り除きません）" >&2; exit 1; }

# 許可の取り消しは、アプリを消す前に行う（消したあとは、`tccutil reset` が「No such bundle identifier」で失敗することがある）。
if [ -n "${RESET_PERMISSIONS:-}" ] || [ -z "${INSTALL_DIR:-}" ]; then
    reset_permissions
else
    echo "許可は取り消していません（INSTALL_DIR を変えているため。取り消すなら RESET_PERMISSIONS=1）"
fi

if [ -d "$DEST" ]; then rm -rf "$DEST"; echo "removed: $DEST"; else echo "入っていません: $DEST"; fi

if [ -z "${INSTALL_DIR:-}" ] || [ -n "${BIN_DIR:-}" ]; then
    LINK="${BIN_DIR:-$HOME/.local/bin}/vc"
    if [ -L "$LINK" ]; then
        if [ "$(readlink "$LINK")" = "$EXE" ]; then rm -f "$LINK"; echo "removed: $LINK"
        else echo "残しました（このアプリを指していない）: $LINK -> $(readlink "$LINK")"; fi
    fi
fi

# メニューの「コマンド vc をインストール」で張ったリンク（/usr/local/bin）は、管理者の権限が要るので、ここでは触らない。
if [ -L /usr/local/bin/vc ]; then
    echo "注意: /usr/local/bin/vc が残っている場合は、アプリの設定 > 一般 の「コマンド vc」を外してから、アプリを取り除いてください"
fi

MODEL="${MODEL_LINK:-$HOME/.voice-control/models/tiny-jev-0.6b}"
if [ -L "$MODEL" ]; then
    rm -f "$MODEL"
    rmdir "$(dirname "$MODEL")" 2>/dev/null || true
    echo "removed: $MODEL"
elif [ -e "$MODEL" ]; then
    echo "残しました（リンクではなく実体）: $MODEL"
fi
