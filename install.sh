#!/bin/bash
# GitHub Release の vc を、コマンド 1 つで入れる（macOS・Apple silicon。管理者権限は不要）。
#
#   curl -fsSL https://raw.githubusercontent.com/takemo101/voice-control/main/install.sh | bash
#   ... | bash -s -- --no-model            # モデルの取得はしない
#   ... | bash -s -- --version 0.1.0       # 版を指定（既定：最新の Release）
#   ... | bash -s -- --bin-dir ~/bin       # 入れる場所（既定：~/.local/bin。環境変数 BIN_DIR でも指定できる）
#
# やること：Release の tar.gz と .sha256 を取得（https だけ）→ SHA-256 を照合 → 取り出した vc を実行して、版を確かめる
# → vc だけを BIN_DIR へ置く（確かめに通らなければ、置かない。いまの vc は、そのまま）→ `vc model download`
# （Tiny-Jev。約 1.2 GB。すでにあれば省略される）→ `vc doctor`（入れた vc にあれば。Apple Intelligence などが使えないとき、手順を見せる）。
# 照合の意味：.sha256 は、同じ出どころ（GitHub）から取るので、転送の途中の破損・欠けを見つける。本物であること（真正性）は、
# GitHub への https に頼る。
# やらないこと：設定・スキル・許可（アクセシビリティ・マイク）には触れない。agent-desktop は入れない（なければ、知らせるだけ）。
# curl で取得したファイルには、Gatekeeper の隔離属性（quarantine）が付かないので、ad-hoc 署名でも、そのまま動く。
# 取り除くとき：rm ~/.local/bin/vc（モデル・設定・スキルは、~/.voice-control に残る）。
# 開発用（ソースからビルドした vc を入れる）は、scripts/install.sh（`just install`）。
#
# 試験用：環境変数 VC_RELEASE_BASE_URL で、取得元（<base>/v<版>/vc-<版>-macos-arm64.tar.gz[.sha256]）を差し替えられる（使うと、知らせる）。
# 全体を main に包んで、最後の行で呼ぶ：`curl | bash` で、途中までしか届かなかったとき、途中までの script を実行しないため。
set -euo pipefail

die() { echo "install.sh: $*" >&2; exit 1; }

main() {
    local repo="takemo101/voice-control"
    local base="${VC_RELEASE_BASE_URL:-https://github.com/$repo/releases/download}"
    local bin="${BIN_DIR:-$HOME/.local/bin}"
    local version="" with_model=1 given_version=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --no-model) with_model=0 ;;
            --version) [ $# -ge 2 ] || die "--version に版を渡してください"; version="${2#v}"; given_version=1; shift ;;
            --bin-dir) [ $# -ge 2 ] || die "--bin-dir に場所を渡してください"; bin="$2"; shift ;;
            -h|--help) echo "使い方: install.sh [--no-model] [--version <版>] [--bin-dir <場所>]（詳しくは、このファイルの先頭のコメント）"; exit 0 ;;
            *) die "知らないオプション: $1（--no-model・--version <版>・--bin-dir <場所>）" ;;
        esac
        shift
    done
    [ "$given_version" = 0 ] || [ -n "$version" ] || die "--version に、空の版は渡せません"

    [ "$(uname -s)" = "Darwin" ] || die "macOS 用です（このシステム：$(uname -s)）"
    [ "$(uname -m)" = "arm64" ] || die "Apple silicon（arm64）用です（このマシン：$(uname -m)）"
    local macos_major
    macos_major="$(sw_vers -productVersion | cut -d. -f1)"
    [ "$macos_major" -ge 26 ] 2>/dev/null || die "macOS 26 以降が要ります（いまは $(sw_vers -productVersion)）"
    command -v curl >/dev/null || die "curl がありません"

    # 入れる場所は、絶対パスにそろえる（PATH の案内を、正しくするため）
    bin="${bin%/}"
    case "$bin" in /*) ;; *) bin="$PWD/$bin" ;; esac

    [ -z "${VC_RELEASE_BASE_URL:-}" ] || echo "注: 取得元を差し替えています: $base" >&2

    if [ -z "$version" ]; then
        # /releases/latest は、最新の Release のタグ（…/releases/tag/vX.Y.Z）へ転送される。API を使わないので、回数の制限に掛からない
        local final
        final="$(curl -fsSL --proto '=https' --proto-redir '=https' -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest")" \
            || die "最新の版を調べられませんでした（--version で指定できます）"
        case "$final" in */releases/tag/v*) ;; *) die "最新の Release が見つかりません（--version で指定できます）" ;; esac
        version="${final##*/v}"
    fi
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版の形が不正です: ${version}（例：0.1.0）"

    local name="vc-$version-macos-arm64"
    local work
    work="$(mktemp -d)"
    trap "rm -rf '$work'" EXIT   # work は main の局所変数。終了時には見えないので、いまの値を埋め込む

    echo "vc $version を取得します"
    curl -fsSL --proto-redir '=https' -o "$work/$name.tar.gz" "$base/v$version/$name.tar.gz" \
        || die "取得できませんでした: $base/v$version/$name.tar.gz（版がない？）"
    curl -fsSL --proto-redir '=https' -o "$work/$name.tar.gz.sha256" "$base/v$version/$name.tar.gz.sha256" \
        || die "SHA-256 を取得できませんでした"

    # tar.gz 自身のハッシュを、自分で計算して比べる（.sha256 に書かれた別のファイルを、照合してしまわないため）
    local expected actual
    expected="$(awk 'NR==1{print $1}' "$work/$name.tar.gz.sha256")"
    actual="$(shasum -a 256 "$work/$name.tar.gz" | awk '{print $1}')"
    [ "${#expected}" -eq 64 ] && [ "$expected" = "$actual" ] || die "SHA-256 が一致しません。入れません"
    echo "SHA-256: OK"

    # 取り出すのは vc だけ（ほかのファイルは、使わない）
    tar -xzf "$work/$name.tar.gz" -C "$work" "$name/vc" || die "tar.gz に $name/vc がありません"

    # 置く前に、取り出した vc が動き、版が合うことを確かめる（通らなければ、いまの vc を、置き換えない）
    local fetched
    fetched="$("$work/$name/vc" --version </dev/null)" || die "取得した vc が動きません。入れません"
    [ "$fetched" = "vc $version" ] || die "取得した vc の版が違います（${fetched}。期待：vc ${version}）。入れません"

    local old=""
    if [ -x "$bin/vc" ]; then
        old="$("$bin/vc" --version </dev/null 2>/dev/null || true)"
        case "$old" in "vc "*) ;; *) echo "注: $bin/vc は、この vc ではないようです。置き換えます" >&2; old="" ;; esac
    fi
    { mkdir -p "$bin" && install -m 755 "$work/$name/vc" "$bin/vc"; } \
        || die "$bin に書き込めません（--bin-dir で、書き込める場所を指定できます。sudo は要りません）"
    echo "installed: $bin/vc（$fetched${old:+。以前：$old}）"

    case ":$PATH:" in *":$bin:"*) ;; *) echo "注: $bin が PATH にありません。シェルの設定（~/.zshrc など）に、export PATH=\"$bin:\$PATH\" を足してください" >&2 ;; esac
    command -v agent-desktop >/dev/null || echo "注: agent-desktop がありません。既定スキルが使います：npm install -g agent-desktop（アクセシビリティの許可：agent-desktop permissions）" >&2

    if [ "$with_model" = 1 ]; then
        echo "Tiny-Jev のモデルを取得します（約 1.2 GB。すでにあれば省略。--no-model で、取得しない）"
        "$bin/vc" model download </dev/null \
            || { echo "install.sh: モデルの取得に失敗しました。vc は入っています。あとで：$bin/vc model download" >&2; exit 1; }
    else
        echo "モデルは取得していません。あとで：vc model download"
    fi
    # この vc に doctor があれば、環境（Apple Intelligence・Tiny-Jev・agent-desktop・許可）を確かめて、使えないものの手順を見せる（古い Release には、ない）
    if "$bin/vc" --help 2>/dev/null | grep -q "^  doctor "; then
        echo; "$bin/vc" doctor </dev/null || true
    fi
    echo "使い方：vc --help / vc skills / vc run \"…\" --dry-run"
}

main "$@"
