#!/bin/bash
# 暫定：Sources/VoiceControlKit の、フォルダ（層）どうしの依存が、下向きだけかを、**型・関数・定数の名前**の `grep` で確かめる。
#   Decision ← Choice ← Skill・Action、 Core ← Skill・Model・Speech（Skill・Action・Speech は、互いに依存しない。Core は、どの層も使ってよい）
# 見えないもの（限界）：他の層の型への `extension` のメンバー（例：`Settings().hotkeySpec`）、動的な参照。
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
    esac
}

LAYERS="Core Decision Choice Model Skill Action Speech"
fail=0

# 層の一覧にないフォルダ・ルート直下のファイルは、検査から漏れるので、失敗にする
for entry in *; do
    if [ -d "$entry" ]; then [[ " $LAYERS " == *" $entry "* ]] || { echo "  層の一覧にないフォルダ: ${entry}（scripts/check-deps.sh に足す）"; fail=1; }
    else echo "  ルート直下のファイル: ${entry}（層のフォルダに入れる）"; fail=1; fi
done

declared() {  # 層の、最上位で宣言した名前（型・typealias・関数・定数）
    grep -rhoE '^(@[A-Za-z]+ )*((public|internal|package|open|final|indirect|nonisolated|private|fileprivate) )*(struct|enum|class|protocol|actor|typealias|func|let|var) [A-Za-z_][A-Za-z0-9_]*' "$1" --include=*.swift | awk '{print $NF}' | sort -u
}

# コメントを除いた行（行頭の `//`、または、最後の `"` より後ろの `//` 以降）を、「ファイル:行:中身」で出す
code_lines() {
    grep -rn '' "$1" --include=*.swift | awk -F: '{
        file=$1; no=$2; line=$0; sub(/^[^:]+:[0-9]+:/, "", line)
        if (line ~ /^[ \t]*\/\//) next
        n=split(line, parts, "\"")      # 最後の " のあとだけ、`//` をコメントとして落とす
        if (n % 2 == 1) { sub(/\/\/.*/, "", parts[n]); line=""; for (i=1;i<=n;i++) line = line parts[i] (i<n ? "\"" : "") }
        print file ":" no ":" line
    }'
}

for layer in $LAYERS; do
    [ -d "$layer" ] || { echo "  層がない: $layer"; fail=1; continue; }
    ok=" $(allowed "$layer") $layer "
    body=$(code_lines "$layer")
    for other in $LAYERS; do
        [[ "$ok" == *" $other "* ]] && continue
        for name in $(declared "$other"); do
            hits=$(echo "$body" | grep -E "(^|[^A-Za-z0-9_])$name([^A-Za-z0-9_]|\$)" | cut -d: -f1,2 | sed "s/\$/: ${name}（${other}）/" || true)
            if [ -n "$hits" ]; then echo "$hits" | sed "s/^/  $layer → $other: /"; fail=1; fi
        done
    done
done
[ "$fail" = 0 ] && echo "依存の向き: 違反なし" || { echo "依存の向き: 違反あり" >&2; exit 1; }
