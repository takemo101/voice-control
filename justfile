# voice-control の開発用コマンド。`just` で一覧を表示する。

set positional-arguments
set shell := ["bash", "-o", "pipefail", "-c"]

vc := justfile_directory() / ".build/release/vc"

default:
    @just --list

# リリースビルド（`.build/release/vc` と Fixture。テスト用の `TestSupport` も、コンパイルされる）。Command Line Tools だけの環境で出る、リンカの「search path ... not found」の警告（無害）は、表示しない
build:
    ./scripts/build-native.sh
    swift build -c release --explicit-target-dependency-import-check=error 2>&1 | { grep -v "ld: warning: search path .*/CommandLineTools/Developer" || true; }

# 単体テスト（Swift Testing）。画面・音声・モデルは使わない
test:
    ./scripts/test.sh

# 配布用の tar.gz と SHA-256 を dist/ に作って、検査する（リリースのワークフローと同じ手順）
package:
    ./scripts/package.sh
    ./scripts/verify-package.sh dist/vc-*-macos-arm64.tar.gz "$(.build/release/vc --version | awk '{print $2}')"

# 開発用に、vc を ~/.local/bin へ入れる（BIN_DIR で場所）。このリポジトリの models/ があれば、~/.voice-control/models/tiny-jev-0.6b から、そこへリンクする。なければ、vc model download で取得
install: build
    ./scripts/install.sh

# install で入れた vc とモデルのリンクを取り除く。モデルの本体（models/・vc model download で置いたもの）と、アクセシビリティ・マイクの許可には触れない
uninstall:
    ./scripts/uninstall.sh

# 自作ウィンドウ（Fixture）を、前面を奪わずに起動する。終了は `just fixture-stop`（ARGS 例: --ja、--many 40）
fixture *args: build
    nohup .build/release/Fixture "$@" >/dev/null 2>&1 &

fixture-stop:
    pkill -x Fixture || true

# 「操作の依頼か」の判定（当てはまるスキルがないとき、既定スキルに回すか）の当たり率（corpus/gate.tsv。Tiny-Jev のモデルが要る）
eval: build
    "{{vc}}" eval-gate corpus/gate.tsv

# ビルドして、vc を呼ぶ（例: just vc run "Safariを開いて" --dry-run / just vc listen --hotkey）
vc *args: build
    "{{vc}}" "$@"
