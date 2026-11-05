#!/bin/bash
# 単体テスト（Swift Testing）。Command Line Tools だけの環境では、SwiftPM がマクロのプラグインを渡さないことがあるので、パスを明示する。
set -euo pipefail
cd "$(dirname "$0")/.."
plugins="$(dirname "$(xcrun -f swiftc)")/../lib/swift/host/plugins/testing"
if [ ! -d "$plugins" ]; then
    echo "error: Swift Testing のマクロプラグインが見つかりません: $plugins" >&2
    exit 1
fi
./scripts/build-native.sh   # 音声認識の実行環境（transcribe.cpp。ビルド済みなら、何もしない）
exec swift test --explicit-target-dependency-import-check=error -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
