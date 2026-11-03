#!/bin/bash
# 暫定：Sources/VoiceControlKit の、フォルダ（層）どうしの依存が、下向きだけかを、型名の `grep` で確かめる。
#   Core ← Decision ← Choice ← Skill・Action、 Core ← Model・Speech（Skill・Action・Speech は、互いに依存しない）
# 次の Issue（MIK-005：ターゲット分割）で、コンパイラによる強制に置き換えて、このスクリプトは消す。
# 使い方：scripts/check-deps.sh（違反があれば、一覧を出して、終了コード 1）
set -euo pipefail
cd "$(dirname "$0")/../Sources/VoiceControlKit"

allowed() {  # 層 → 使ってよい層（自分自身を除く）
    case "$1" in
        Core) echo "" ;;
        Decision) echo "Core" ;;
        Choice) echo "Core Decision" ;;
        Model) echo "Core" ;;
        Skill) echo "Core Decision Choice" ;;
        Action) echo "Core Decision Choice" ;;
        Speech) echo "Core" ;;
        *) echo "?" ;;
    esac
}

LAYERS="Core Decision Choice Model Skill Action Speech"
declared() {  # 層の、最上位で宣言した型名（struct・enum・class・protocol・actor）
    grep -rhoE '^(public |internal |final |public final )*(struct|enum|class|protocol|actor) [A-Z][A-Za-z0-9]*' "$1" | awk '{print $NF}' | sort -u
}

fail=0
for layer in $LAYERS; do
    [ -d "$layer" ] || { echo "層がない: $layer"; fail=1; continue; }
    ok=" $(allowed "$layer") $layer "
    for other in $LAYERS; do
        [[ "$ok" == *" $other "* ]] && continue
        for name in $(declared "$other"); do
            # コメントを除いた行で、単語として使われているか
            hits=$(grep -rnwE "$name" "$layer" --include=*.swift | sed -E 's#^([^:]+:[0-9]+):(.*)$#\1:\2#' | awk -F: '{ line=$0; sub(/^[^:]+:[0-9]+:/, "", line); sub(/\/\/.*/, "", line); if (line ~ "(^|[^A-Za-z0-9_])'"$name"'([^A-Za-z0-9_]|$)") print $1":"$2": '"$name"'（'"$other"'）" }' || true)
            if [ -n "$hits" ]; then echo "$layer → $other: $hits" | sed 's/^/  /'; fail=1; fi
        done
    done
done
[ "$fail" = 0 ] && echo "依存の向き: 違反なし" || { echo "依存の向き: 違反あり" >&2; exit 1; }
