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

# 英語の翻訳（設定ウィンドウとダイアログ）の抜け・重複・包まれていない日本語の文字列
l10n:
    python3 scripts/check-l10n.py --uncovered

# build/VoiceControl.app（メニューバーのアプリ。Apple silicon、ad-hoc 署名）を作る
app:
    ./scripts/build-app.sh

# dist/vc-<版>-macos-arm64.dmg を作って、検査する（アプリの中の vc は、CLI の vc と同じもの）
dmg:
    ./scripts/dmg.sh
    ./scripts/verify-dmg.sh dist/vc-*-macos-arm64.dmg "$(.build/release/vc --version | awk '{print $2}')"

# 開発用に、アプリを ~/Applications へ入れて、起動する（INSTALL_DIR で場所、NO_OPEN=1 で起動なし、RESET_PERMISSIONS=1 で許可を取り消してから）。コマンド vc は ~/.local/bin へリンク。リポジトリの models/tiny-jev-0.6b があれば、~/.voice-control/models/tiny-jev-0.6b へリンク
install: app
    ./scripts/install.sh

# install で入れたアプリ・コマンド vc のリンク・モデルのリンクを取り除く（既定の場所なら、許可も取り消す）。モデルの本体・スキル・設定には触れない
uninstall:
    ./scripts/uninstall.sh

# このアプリの許可（マイク・アクセシビリティ・画面収録）を取り消す（設定ではオンなのに「許可されていません」と出るとき。次の起動で、確認が出る）
reset-permissions:
    ./scripts/reset-permissions.sh

# 自作ウィンドウ（Fixture）を、前面を奪わずに起動する。終了は `just fixture-stop`（ARGS 例: --ja、--many 40）
fixture *args: build
    nohup .build/release/Fixture "$@" >/dev/null 2>&1 &

fixture-stop:
    pkill -x Fixture || true

# 「操作の依頼か」の判定（当てはまるスキルがないとき、既定スキルに回すか）の当たり率（corpus/gate.tsv。Tiny-Jev のモデルが要る）
eval: build
    "{{vc}}" eval-gate corpus/gate.tsv

# ビルドして、vc（CLI）を呼ぶ（例: just vc run "Safariを開いて" --dry-run）
vc *args: build
    "{{vc}}" "$@"
