# voice-control の開発用コマンド。`just` で一覧を表示する。

set positional-arguments
set shell := ["bash", "-o", "pipefail", "-c"]

vc := justfile_directory() / ".build/release/vc"

default:
    @just --list

# リリースビルド（.build/release/vc と Fixture）。Command Line Tools だけの環境で出る、リンカの「search path ... not found」の警告（無害）は、表示しない
build:
    swift build -c release 2>&1 | { grep -v "ld: warning: search path .*/CommandLineTools/Developer" || true; }

# Tiny-Jev 0.6B（約 1.2 GB）を、版を固定して models/ に取得し、SHA-256 を検証する（取得済みなら何もしない）
fetch-model:
    ./scripts/fetch-model.sh

# 単体テスト（Swift Testing）。画面・音声・モデルは使わない
test:
    ./scripts/test.sh

# 配布用の tar.gz と SHA-256 を dist/ に作って、検査する（リリースのワークフローと同じ手順）
package:
    ./scripts/package.sh
    ./scripts/verify-package.sh dist/vc-*-macos-arm64.tar.gz "$(.build/release/vc --version | awk '{print $2}')"

# 開発用に、vc を ~/.local/bin へ入れる（BIN_DIR で場所）。モデルは、このリポジトリの models/ を、~/Library/Application Support/voice-control/models から指す
install: build
    ./scripts/install.sh

# install で入れた vc とモデルのリンクを取り除く。モデルの本体（models/）と、アクセシビリティ・マイクの許可には触れない
uninstall:
    ./scripts/uninstall.sh

# 自作ウィンドウ（Fixture）を、前面を奪わずに起動する。終了は `just fixture-stop`（ARGS 例: --ja、--many 40）
fixture *args: build
    nohup .build/release/Fixture "$@" >/dev/null 2>&1 &

fixture-stop:
    pkill -x Fixture || true

# 固定した画面での、操作の当たり率（実機は操作しない。SPEAK=1 で、say → 文字起こし経由）
eval: build
    "{{vc}}" eval corpus/plans.tsv ${SPEAK:+--speak}

# ビルドして、vc を呼ぶ（例: just vc plan "下にスクロールして" / just vc listen --execute）
vc *args: build
    "{{vc}}" "$@"
