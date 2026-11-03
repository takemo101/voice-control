#!/bin/bash
# GitHub Release の vc を、コマンド 1 つで入れる（macOS・Apple silicon。管理者権限は不要）。
#
#   curl -fsSL https://raw.githubusercontent.com/takemo101/voice-control/main/install.sh | bash
#   ... | bash -s -- --no-model            # モデルの取得はしない
#   ... | bash -s -- --version 0.1.0       # 版を指定（既定：最新の Release）
#   ... | bash -s -- --bin-dir ~/bin       # 入れる場所（既定：~/.local/bin。環境変数 BIN_DIR でも指定できる）
#
# やること：Release の tar.gz と .sha256 を取得 → SHA-256 を照合 → vc だけを BIN_DIR へ置く → `vc model download`（Tiny-Jev。約 1.2 GB。
# すでにあれば省略される）。置いたあとに `vc --version` を実行して確かめる。
# やらないこと：設定・スキル・許可（アクセシビリティ・マイク）には触れない。agent-desktop は入れない（なければ、知らせるだけ）。
# curl で取得したファイルには、Gatekeeper の隔離属性（quarantine）が付かないので、ad-hoc 署名でも、そのまま動く。
# 取り除くとき：rm ~/.local/bin/vc（モデル・設定・スキルは、~/.voice-control に残る）。
# 開発用（ソースからビルドした vc を入れる）は、scripts/install.sh（`just install`）。
#
# 試験用：環境変数 VC_RELEASE_BASE_URL で、取得元（<base>/v<版>/vc-<版>-macos-arm64.tar.gz[.sha256]）を差し替えられる。
set -euo pipefail

REPO="takemo101/voice-control"
BASE="${VC_RELEASE_BASE_URL:-https://github.com/$REPO/releases/download}"
BIN="${BIN_DIR:-$HOME/.local/bin}"
VERSION=""
WITH_MODEL=1

die() { echo "install.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --no-model) WITH_MODEL=0 ;;
        --version) [ $# -ge 2 ] || die "--version に版を渡してください"; VERSION="${2#v}"; shift ;;
        --bin-dir) [ $# -ge 2 ] || die "--bin-dir に場所を渡してください"; BIN="$2"; shift ;;
        -h|--help) echo "使い方: install.sh [--no-model] [--version <版>] [--bin-dir <場所>]（詳しくは、このファイルの先頭のコメント）"; exit 0 ;;
        *) die "知らないオプション: $1（--no-model・--version <版>・--bin-dir <場所>）" ;;
    esac
    shift
done

[ "$(uname -s)" = "Darwin" ] || die "macOS 用です（このシステム：$(uname -s)）"
[ "$(uname -m)" = "arm64" ] || die "Apple silicon（arm64）用です（このマシン：$(uname -m)）"
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$macos_major" -ge 26 ] 2>/dev/null || die "macOS 26 以降が要ります（いまは $(sw_vers -productVersion)）"
command -v curl >/dev/null || die "curl がありません"

if [ -z "$VERSION" ]; then
    # /releases/latest は、最新の Release のタグ（…/tag/vX.Y.Z）へ転送される。API を使わないので、回数の制限に掛からない
    final="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")" || die "最新の版を調べられませんでした（--version で指定できます）"
    VERSION="${final##*/v}"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版の形が不正です: ${VERSION}（例：0.1.0）"

NAME="vc-$VERSION-macos-arm64"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "vc $VERSION を取得します"
curl -fsSL -o "$WORK/$NAME.tar.gz" "$BASE/v$VERSION/$NAME.tar.gz" || die "取得できませんでした: $BASE/v$VERSION/$NAME.tar.gz（版がない？）"
curl -fsSL -o "$WORK/$NAME.tar.gz.sha256" "$BASE/v$VERSION/$NAME.tar.gz.sha256" || die "SHA-256 を取得できませんでした"
(cd "$WORK" && shasum -a 256 -c "$NAME.tar.gz.sha256" >/dev/null) || die "SHA-256 が一致しません。入れません"
echo "SHA-256: OK"

# 取り出すのは vc だけ（ほかのファイルは、使わない）
tar -xzf "$WORK/$NAME.tar.gz" -C "$WORK" "$NAME/vc" || die "tar.gz に $NAME/vc がありません"

old=""
[ -x "$BIN/vc" ] && old="$("$BIN/vc" --version 2>/dev/null || true)"
mkdir -p "$BIN"
install -m 755 "$WORK/$NAME/vc" "$BIN/vc"
installed="$("$BIN/vc" --version)" || die "入れた vc が動きません: $BIN/vc"
[ "$installed" = "vc $VERSION" ] || die "入れた vc の版が違います（${installed}。期待：vc ${VERSION}）"
echo "installed: $BIN/vc（$installed${old:+。以前：$old}）"

case ":$PATH:" in *":$BIN:"*) ;; *) echo "注: $BIN が PATH にありません。シェルの設定（~/.zshrc など）に、export PATH=\"$BIN:\$PATH\" を足してください" >&2 ;; esac
command -v agent-desktop >/dev/null || echo "注: agent-desktop がありません。既定スキルが使います：npm install -g agent-desktop（アクセシビリティの許可：agent-desktop permissions）" >&2

if [ "$WITH_MODEL" = 1 ]; then
    echo "Tiny-Jev のモデルを取得します（約 1.2 GB。すでにあれば省略。--no-model で、取得しない）"
    "$BIN/vc" model download </dev/null || { echo "install.sh: モデルの取得に失敗しました。vc は入っています。あとで：$BIN/vc model download" >&2; exit 1; }
else
    echo "モデルは取得していません。あとで：vc model download"
fi
echo "使い方：vc --help / vc skills / vc run \"…\" --dry-run"
