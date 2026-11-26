#!/bin/sh
# 今日の Todo と、時間になったら、読み上げて、パネルを出す（`todo-remind` スキルの本体。`todo.applescript` から呼ばれる）。
# 使い方：/bin/sh todo.sh add <時刻> "<内容>" | run <時刻> "<依頼>" | list | delete "<語>" | delete all（<時刻>：15:00・15時半・午後3時・5分後・1時間半後 など）。内部用：wait <epoch> <スキル|-> "<内容>"・time "<時刻>"・relative "<5分後 など>"
#
# `run`：**時刻に、スキルを実行する予約**（`vc run`）。安全のために：①登録のとき、`vc run --dry-run` で、**特定のスキルに当たる**ときだけ受ける（既定スキル・このスキル自身・確認が要るスキルは、断る）②時刻になったら、**10 秒の予告**（読み上げ＋パネル。パネルを閉じると、取りやめ）③実行は、選ばれたスキルを指定して、`--yes` なしで（確認が要る操作は、無人だと「いいえ」になり、実行されない）④時刻から 2 分以上遅れたら（スリープなど）、実行しない。
#
# 置き場所：**待機しているプロセスそのもの**（`/bin/sh …/todo.sh wait <epoch> <スキル|-> <内容>`）。ファイルにも、ログにも、残さない。
# Mac の再起動・ログアウトで、消える。一覧は `ps` で、取り消しは、そのプロセスを止めて、行う。
# 結果は、いつも、1 行（ok: …・error: …）。標準出力へ（終了コードは 0）。
LC_ALL=en_US.UTF-8
export LC_ALL
dir=$(cd "$(dirname "$0")" && pwd)
self="$dir/todo.sh"
prefix="/bin/sh $self wait "   # 待機プロセスの印（この形で、始まる行だけを、自分のものとする）
max_items=20
max_chars=100
confirm_seconds=10   # 予約の実行の、予告の長さ（この間に、パネルを閉じると、取りやめ）
late_limit=120       # 予約の実行は、時刻から、これ以上遅れたら、しない
run_limit=180        # 予約の実行（`vc run`）の、上限（秒）

# `vc`：メニューバーのアプリから呼ばれたときは、PATH に、ないことがある
find_vc() {
	for candidate in "$(command -v vc 2>/dev/null)" "$HOME/.local/bin/vc" "/Applications/VoiceControl.app/Contents/MacOS/vc" "$HOME/Applications/VoiceControl.app/Contents/MacOS/vc"; do
		if [ -n "$candidate" ] && [ -x "$candidate" ]; then
			printf '%s' "$candidate"
			return 0
		fi
	done
	return 1
}

# 待機中の Todo：`pid<TAB>epoch<TAB>内容` を、時刻の順に（実行の予約は、「▶ 依頼（スキル名）」）
pending() {
	/bin/ps -axww -o pid=,command= | /usr/bin/awk -v pre="$prefix" -v now="$(/bin/date +%s)" '
		{
			pid = $1
			cmd = $0
			sub(/^ *[0-9]+ +/, "", cmd)
			if (index(cmd, pre) != 1) next
			rest = substr(cmd, length(pre) + 1)
			n = index(rest, " ")
			if (n == 0) next
			epoch = substr(rest, 1, n - 1)
			if (epoch + 0 <= now + 0) next   # 時刻が来て、いま、読み上げている最中のものは、出さない
			rest = substr(rest, n + 1)
			n = index(rest, " ")
			if (n == 0) next
			skill = substr(rest, 1, n - 1)
			text = substr(rest, n + 1)
			if (skill != "-") text = "▶ " text "（" skill "）"
			printf "%s\t%s\t%s\n", pid, epoch, text
		}' | /usr/bin/sort -t "$(printf '\t')" -k2,2n
}

# Markdown の一覧（表）
markdown() {
	list=$(pending)
	if [ -z "$list" ]; then
		printf '# 今日の Todo\n\nありません。\n'
		return
	fi
	count=$(printf '%s\n' "$list" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
	printf '# 今日の Todo（%s 件）\n\n| 時刻 | 内容 |\n|---|---|\n' "$count"
	printf '%s\n' "$list" | while IFS="$(printf '\t')" read -r _ epoch text; do
		printf '| %s | %s |\n' "$(/bin/date -r "$epoch" +%H:%M)" "$(printf '%s' "$text" | /usr/bin/sed 's/|/\\|/g')"
	done
}

# 前に出した一覧のパネルを、閉じる（追加・削除のたびに、増えないように）。閉じるのは、この題名の、`vc show` だけ
list_title="今日の Todo"
list_seconds=20     # 一覧のパネルは、この秒数で、黙って閉じる（`vc show --timeout`）
alert_seconds=60    # 時間の知らせのパネルは、見逃さないよう、長めに
close_list_panels() {
	/bin/ps -axww -o pid=,command= | /usr/bin/awk -v t=" --title $list_title" '{ pid = $1; sub(/^ *[0-9]+ +/, ""); if (index($0, " show --wait ") > 0 && index($0, t) > 0) print pid }' | while read -r pid; do kill "$pid" 2>/dev/null; done
}

# 文字を、合成した形（NFC）にそろえる。**アプリが起こしたコマンドの引数は、濁点が、分かれた形（NFD：「ご」→「こ」＋゛）で届く**（Foundation の `Process`）ので、そのままでは、「ごろ」などが、照合できない・保存と検索の形がずれる
nfc() {
	printf '%s' "$1" | /usr/bin/iconv -f UTF-8-MAC -t UTF-8 2>/dev/null || printf '%s' "$1"
}

# 時刻の言い方を、HH:MM（24 時間）にする：「15:00」「9:30」「15時」「15時半」「9時15分」「午後3時半」「夜の8時」「正午」。
# **言語モデルは、午後・半の計算を、間違える**（10時半を 11:30 に、午後3時を 15:30 にした）ので、読むのは、ここ（コード）。読めなければ、何も出さずに、戻り値 1。
# 日本語の文字は、シェルの `case`・`${…%…}` だけで扱う（`sed`・`tr` の正規表現・文字の範囲は、ロケールや環境で、日本語を壊すことがあった）。
parse_time() {
	words=$(nfc "$1" | /usr/bin/sed 's/０/0/g; s/１/1/g; s/２/2/g; s/３/3/g; s/４/4/g; s/５/5/g; s/６/6/g; s/７/7/g; s/８/8/g; s/９/9/g; s/：/:/g; s/ //g; s/　//g')
	words=${words%ごろ}
	words=${words%頃}
	words=${words%に}
	if [ "$words" = "正午" ]; then printf '12:00'; return 0; fi
	period=""
	case "$words" in
	午前*) period=am; words=${words#午前} ;;
	朝*) period=am; words=${words#朝} ;;
	あさ*) period=am; words=${words#あさ} ;;
	午後*) period=pm; words=${words#午後} ;;
	夕方*) period=pm; words=${words#夕方} ;;
	夕*) period=pm; words=${words#夕} ;;
	昼*) period=pm; words=${words#昼} ;;
	ごご*) period=pm; words=${words#ごご} ;;
	夜*) period=night; words=${words#夜} ;;
	晩*) period=night; words=${words#晩} ;;
	よる*) period=night; words=${words#よる} ;;
	esac
	words=${words#の}
	case "$words" in
	*:*) hour=${words%%:*}; minute=${words#*:} ;;
	*時半) hour=${words%時半}; minute=30 ;;
	*時*) hour=${words%%時*}; minute=${words#*時}; minute=${minute%分}; [ -n "$minute" ] || minute=0 ;;
	*) hour=$words; minute=0 ;;   # 数だけ（「10」）：言語モデルが「時」を落としても、時として読む（数字でなければ、下で断る）
	esac
	for number in "$hour" "$minute"; do
		case "$number" in
		''|*[!0-9]*) return 1 ;;
		esac
		[ "${#number}" -le 2 ] || return 1
	done
	hour=$((10#$hour))
	minute=$((10#$minute))
	[ "$hour" -le 23 ] && [ "$minute" -le 59 ] || return 1
	case "$period" in
	am) [ "$hour" -eq 12 ] && hour=0 ;;
	pm) [ "$hour" -ge 1 ] && [ "$hour" -le 11 ] && hour=$((hour + 12)) ;;
	night)
		if [ "$hour" -ge 5 ] && [ "$hour" -le 11 ]; then hour=$((hour + 12)); elif [ "$hour" -eq 12 ]; then hour=0; fi ;;
	esac
	printf '%02d:%02d' "$hour" "$minute"
}

# 声で知らせる（背景で）
speak() {
	(/usr/bin/say -v Kyoko "$1" || /usr/bin/say "$1") >/dev/null 2>&1 &
}

# 予約の実行（`wait` から：`target`・`skill`・`text`・`late` を使う）：予告 → 実行 → 結果の知らせ
run_item() {
	if [ "$late" -gt "$late_limit" ]; then
		speak "時刻を過ぎていたので、「${text}」は、実行しませんでした"
		return
	fi
	if ! vc=$(find_vc); then
		speak "vc が見つからないので、「${text}」を、実行できません"
		return
	fi
	# 予告：パネルが、閉じられずに、`confirm_seconds` 残れば、実行。閉じられたら（早く終わったら）、取りやめ。**パネルを出せなかったときも、取りやめ**（安全側）
	speak "${confirm_seconds}秒後に、「${text}」を実行します。やめるときは、パネルを閉じてください"
	started=$(/bin/date +%s)
	printf '# %s 秒後に実行します\n\n## %s\n\nスキル：%s\n\n**やめるときは、このパネルを閉じてください（Esc）。**\n' "$confirm_seconds" "$text" "$skill" | "$vc" show --wait --title "予約の実行" --timeout "$confirm_seconds" >/dev/null 2>&1
	if [ "$(( $(/bin/date +%s) - started ))" -lt "$((confirm_seconds - 1))" ]; then
		speak "取りやめました"
		return
	fi
	# 実行：選ばれたスキルを指定して、`--yes` なし・標準入力なし（確認が要る操作は、「いいえ」になる）
	output=$(/usr/bin/perl -e 'alarm shift; exec @ARGV' "$run_limit" "$vc" run "$text" --skill "$skill" --no-plan </dev/null 2>&1)
	reply=$(printf '%s\n' "$output" | /usr/bin/grep -E '^ +[^ ]+ +(done|failed):' | /usr/bin/head -1 | /usr/bin/sed -E 's/^ +[^ ]+ +//')
	case "$reply" in
	done:*)
		speak "「${text}」を、実行しました"
		printf '# 実行しました\n\n## %s\n\nスキル：%s\n\n%s\n' "$text" "$skill" "${reply#done:}" | "$vc" show --title "予約の実行" --timeout "$alert_seconds" >/dev/null 2>&1
		;;
	*)
		speak "「${text}」は、実行できませんでした"
		printf '# 実行できませんでした\n\n## %s\n\nスキル：%s\n\n確認が要る操作・失敗のどちらかです。%s\n' "$text" "$skill" "${reply#failed:}" | "$vc" show --title "予約の実行" --timeout "$alert_seconds" >/dev/null 2>&1
		;;
	esac
}

# 「5分後」「1時間後」「1時間半後」「1時間30分後」「90秒後」を、秒数にする（標準出力）。読めなければ、何も出さずに、戻り値 1。「後」は、なくてもよい（「5分」）。
# 言語モデルに、いまの時刻からの足し算は、させない（コードが、足す）。上限は 24 時間。
parse_relative() {
	words=$(nfc "$1" | /usr/bin/sed 's/０/0/g; s/１/1/g; s/２/2/g; s/３/3/g; s/４/4/g; s/５/5/g; s/６/6/g; s/７/7/g; s/８/8/g; s/９/9/g; s/ //g; s/　//g')
	words=${words%に}
	words=${words%後}
	hours=0; minutes=0; seconds=0
	case "$words" in
	*時間半) hours=${words%時間半}; minutes=30 ;;
	*時間*分) hours=${words%%時間*}; minutes=${words#*時間}; minutes=${minutes%分} ;;
	*時間) hours=${words%時間} ;;
	*分) minutes=${words%分} ;;
	*秒) seconds=${words%秒} ;;
	*) return 1 ;;
	esac
	for number in "$hours" "$minutes" "$seconds"; do
		case "$number" in
		''|*[!0-9]*) return 1 ;;
		esac
		[ "${#number}" -le 3 ] || return 1
	done
	total=$((10#$hours * 3600 + 10#$minutes * 60 + 10#$seconds))
	[ "$total" -gt 0 ] && [ "$total" -le 86400 ] || return 1
	printf '%s' "$total"
}

# 時刻（「15時」「5分後」）→ 目標の時刻（epoch）。**今日の中だけ**（日をまたぐ・過ぎた時刻は、断る）。読めなければ、戻り値 1・過ぎた／明日なら、戻り値 2。
resolve_epoch() {
	if offset=$(parse_relative "$1"); then
		epoch=$(( $(/bin/date +%s) + offset ))
	elif time_text=$(parse_time "$1"); then
		epoch=$(/bin/date -j -f "%Y-%m-%d %H:%M:%S" "$(/bin/date +%Y-%m-%d) $time_text:00" +%s)
	else
		return 1
	fi
	[ "$epoch" -gt "$(/bin/date +%s)" ] || return 2
	[ "$(/bin/date -r "$epoch" +%Y-%m-%d)" = "$(/bin/date +%Y-%m-%d)" ] || return 2
	return 0
}

# 一覧のパネル（`vc` がなければ、出さない。出したか否かを、戻り値で）
show_panel() {
	vc=$(find_vc) || return 1
	close_list_panels
	markdown | "$vc" show --title "$list_title" --timeout "$list_seconds" >/dev/null 2>&1
}

# 一覧の文：「15:00 内容 / 16:00 内容」（`vc` がなければ、これを、結果に添える）
summary() {
	describe "$(pending)"
}

# `pid<TAB>epoch<TAB>内容` の行を、「15:00 内容 / 16:00 内容」にする
describe() {
	printf '%s\n' "$1" | while IFS="$(printf '\t')" read -r _ epoch text; do
		[ -n "$epoch" ] && printf '%s %s\n' "$(/bin/date -r "$epoch" +%H:%M)" "$text"
	done | /usr/bin/awk 'NR > 1 { printf " / " } { printf "%s", $0 } END { print "" }'
}

# 内容：制御文字を落とし、空白を整え、長さを切る
clean() {
	nfc "$1" | /usr/bin/tr -d '[:cntrl:]' | /usr/bin/sed 's/^ *//; s/ *$//' | /usr/bin/cut -c1-"$max_chars"
}

case "${1:-}" in
time)
	# 内部用（テスト）：時刻の言い方を読む
	parse_time "${2:-}" || echo "error"
	;;
relative)
	# 内部用（テスト）：「5分後」などを、秒数に
	parse_relative "${2:-}" || echo "error"
	;;
wait)
	# 内部用：時刻まで、壁時計で待つ（`sleep` だけだと、スリープの間が数えられない）→ 読み上げ → パネル
	target=${2:-0}
	skill=${3:--}
	text=${4:-}
	while :; do
		now=$(/bin/date +%s)
		remaining=$((target - now))
		[ "$remaining" -le 0 ] && break
		if [ "$remaining" -gt 5 ]; then /bin/sleep 5; else /bin/sleep "$remaining"; fi
	done
	late=$((now - target))
	if [ "$skill" != "-" ]; then
		run_item
		wait
		exit 0
	fi
	sentence="${text}を実施する時間です"
	[ "$late" -gt 60 ] && sentence="遅れました。${sentence}"
	(/usr/bin/say -v Kyoko "$sentence" || /usr/bin/say "$sentence") >/dev/null 2>&1 &
	if vc=$(find_vc); then
		printf '# 時間です\n\n## %s\n\n%s に設定した Todo です。\n' "$text" "$(/bin/date -r "$target" +%H:%M)" | "$vc" show --title "Todo の時間" --timeout "$alert_seconds" >/dev/null 2>&1
	fi
	wait
	;;
add)
	text=$(clean "${3:-}")
	resolve_epoch "${2:-}"
	case $? in
	1) echo "error: could not read the time \"${2:-}\" (use e.g. 15:00, 15時半, 午後3時, 5分後)"; exit 0 ;;
	2) echo "error: that time has already passed or is not today (only times later today can be set)"; exit 0 ;;
	esac
	if [ -z "$text" ]; then
		echo "error: the todo text is empty"
		exit 0
	fi
	if [ "$(pending | /usr/bin/wc -l | /usr/bin/tr -d ' ')" -ge "$max_items" ]; then
		echo "error: too many todos ($max_items). delete some first"
		exit 0
	fi
	/usr/bin/nohup /bin/sh "$self" wait "$epoch" - "$text" >/dev/null 2>&1 </dev/null &
	/bin/sleep 0.3   # 待機プロセスが、一覧に出るまで、少し待つ
	panel=""
	show_panel || panel=" (no panel: vc not found) todos: $(summary)"
	echo "ok: added $(/bin/date -r "$epoch" +%H:%M) $text$panel"
	;;
run)
	text=$(clean "${3:-}")
	resolve_epoch "${2:-}"
	case $? in
	1) echo "error: could not read the time \"${2:-}\" (use e.g. 15:00, 15時半, 午後3時, 5分後)"; exit 0 ;;
	2) echo "error: that time has already passed or is not today (only times later today can be set)"; exit 0 ;;
	esac
	if [ -z "$text" ]; then
		echo "error: the request is empty"
		exit 0
	fi
	if [ "$(pending | /usr/bin/wc -l | /usr/bin/tr -d ' ')" -ge "$max_items" ]; then
		echo "error: too many todos ($max_items). delete some first"
		exit 0
	fi
	if ! vc=$(find_vc); then
		echo "error: vc was not found, so the request cannot be checked or scheduled"
		exit 0
	fi
	# 登録のとき、先に確かめる：どのスキルが、選ばれるか（dry-run：実行しない）
	dry=$(/usr/bin/perl -e 'alarm shift; exec @ARGV' 90 "$vc" run "$text" --dry-run --no-plan </dev/null 2>&1)
	skill=$(printf '%s\n' "$dry" | /usr/bin/sed -n -E 's/^ *Tiny-Jev +([a-z0-9][a-z0-9-]*) +[0-9.]+%.*/\1/p' | /usr/bin/head -1)
	if [ -z "$skill" ]; then
		echo "error: that request does not match a specific skill, so it cannot be scheduled (only requests that match a skill can be scheduled)"
		exit 0
	fi
	if [ "$skill" = "todo-remind" ]; then
		echo "error: that request is about the todo list itself, so it cannot be scheduled"
		exit 0
	fi
	if /usr/bin/awk '/^---/ { n++; next } n == 1 && /^confirm: *true/ { found = 1 } END { exit !found }' "$dir/../$skill/SKILL.md" 2>/dev/null; then
		echo "error: the skill $skill asks for confirmation, so it cannot run unattended and cannot be scheduled"
		exit 0
	fi
	planned=$(printf '%s\n' "$dry" | /usr/bin/sed -n -E 's/^ +\$ //p' | /usr/bin/sed -E 's|[^ ]*/skills/[a-z0-9-]+/||g' | /usr/bin/head -3 | /usr/bin/awk 'NR > 1 { printf " ; " } { printf "%s", $0 } END { print "" }')
	/usr/bin/nohup /bin/sh "$self" wait "$epoch" "$skill" "$text" >/dev/null 2>&1 </dev/null &
	/bin/sleep 0.3
	panel=""
	show_panel || panel=" (no panel: vc not found)"
	echo "ok: scheduled $(/bin/date -r "$epoch" +%H:%M) run [$skill] $text (will run: $planned). ${confirm_seconds} seconds before, a notice appears; closing it cancels$panel"
	;;
list)
	count=$(pending | /usr/bin/wc -l | /usr/bin/tr -d ' ')
	if show_panel; then echo "ok: $count todos shown in the panel"; else echo "ok: $count todos: $(summary)"; fi
	;;
delete)
	word=$(clean "${2:-}")
	if [ -z "$word" ]; then
		echo "error: say which todo to delete (a word from it), or 'all'"
		exit 0
	fi
	list=$(pending)
	if [ "$word" = "all" ]; then
		matches=$list
	else
		matches=$(printf '%s\n' "$list" | /usr/bin/awk -F '\t' -v w="$word" 'index(tolower($3), tolower(w)) > 0')
	fi
	if [ -z "$matches" ] && [ "$word" != "all" ]; then
		# 語の最後の助詞（の・を・に・は・が・で・と・も）を落として、もう一度（「請求書の」→「請求書」）
		trimmed=$(printf '%s' "$word" | /usr/bin/sed 's/[のをにはがでともへ]$//')
		if [ -n "$trimmed" ] && [ "$trimmed" != "$word" ]; then
			word=$trimmed
			matches=$(printf '%s\n' "$list" | /usr/bin/awk -F '\t' -v w="$word" 'index(tolower($3), tolower(w)) > 0')
		fi
	fi
	if [ -z "$matches" ]; then
		echo "error: no todo matches \"$word\""
		exit 0
	fi
	if [ "$word" != "all" ] && [ "$(printf '%s\n' "$matches" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" -gt 1 ]; then
		echo "error: several todos match \"$word\": $(describe "$matches"). use a more specific word"
		exit 0
	fi
	removed=$(printf '%s\n' "$matches" | while IFS="$(printf '\t')" read -r pid epoch text; do
		# 止める前に、その番号が、いまも、自分の待機プロセスか、確かめる（番号の使い回しで、別のプロセスを止めない）
		if pending | /usr/bin/awk -F '\t' -v p="$pid" -v e="$epoch" '$1 == p && $2 == e { found = 1 } END { exit !found }'; then
			kill "$pid" 2>/dev/null && printf '%s\t%s\t%s\n' "$pid" "$epoch" "$text"
		fi
	done)
	/bin/sleep 0.2
	show_panel
	echo "ok: deleted $(describe "$removed")"
	;;
*)
	echo "error: unknown action. use add <time> \"<text>\" | run <time> \"<request>\" | list | delete \"<word>\" | delete all"
	;;
esac
exit 0
