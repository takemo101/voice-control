#!/bin/bash
# ACP アダプターの固定ファイル（adapters/<名前>/package.json・package-lock.json）を、新しい版で作り直す。
#   ./scripts/update-adapters.sh claude 0.109.0     … 版を指定
#   ./scripts/update-adapters.sh codex              … npm の最新の版
# そのあと：①`Sources/VCSkill/Chat/ACP/ACPAdapter.swift` の `version` を、同じ版にする（テストが照らす）②`just test` ③実際のエージェントで `vc chat-check`（docs/verification.md）④変更を、PR にする。
# lock は npm の公式のレジストリ・SHA-512 だけ（アプリが、入れる前にも検査する）。インストール時のスクリプトは動かさない（--ignore-scripts）。
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  claude) PACKAGE="@agentclientprotocol/claude-agent-acp" ;;
  codex)  PACKAGE="@agentclientprotocol/codex-acp" ;;
  *) echo "使い方: $0 claude|codex [版]" >&2; exit 2 ;;
esac
NAME="$1"
VERSION="${2:-$(npm view "$PACKAGE" version)}"
DIR="adapters/$NAME"
mkdir -p "$DIR"
cat > "$DIR/package.json" <<JSON
{
  "name": "voice-control-adapter-$NAME",
  "version": "1.0.0",
  "private": true,
  "description": "voice-control が、利用者の操作で入れる、ACP アダプター（版を固定）",
  "dependencies": { "$PACKAGE": "$VERSION" }
}
JSON
rm -f "$DIR/package-lock.json"
(cd "$DIR" && npm install --package-lock-only --ignore-scripts --no-audit --no-fund >/dev/null)
echo "$PACKAGE@$VERSION を固定しました（$DIR）。ACPAdapter.swift の version も、$VERSION にしてください。"
