#!/bin/sh
# 今日の Todo と、時間になったら、読み上げて、パネルを出す（`todo-remind` スキルの本体。`todo.applescript` から呼ばれる）。
# 使い方：/bin/sh todo.sh add <時刻> "<内容>" | list | delete "<語>" | delete all（<時刻>：15:00・15時半・午後3時 など）。内部用：wait <epoch> "<内容>"・time "<時刻>"
#
# 置き場所：**待機しているプロセスそのもの**（`/bin/sh …/todo.sh wait <epoch> <内容>`）。ファイルにも、ログにも、残さない。
# Mac の再起動・ログアウトで、消える。一覧は `ps` で、取り消しは、そのプロセスを止めて、行う。
# 結果は、いつも、1 行（ok: …・error: …）。標準出力へ（終了コードは 0）。
LC_ALL=en_US.UTF-8
export LC_ALL
dir=$(cd "$(dirname "$0")" && pwd)
self="$dir/todo.sh"
prefix="/bin/sh $self wait "   # 待機プロセスの印（この形で、始まる行だけを、自分のものとする）
max_items=20
max_chars=100

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

# 待機中の Todo：`pid<TAB>epoch<TAB>内容` を、時刻の順に
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
			printf "%s\t%s\t%s\n", pid, epoch, substr(rest, n + 1)
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
close_list_panels() {
	/bin/ps -axww -o pid=,command= | /usr/bin/awk -v t="--title $list_title" '{ pid = $1; sub(/^ *[0-9]+ +/, ""); n = index($0, " show --wait "); if (n > 0 && substr($0, length($0) - length(t) + 1) == t) print pid }' | while read -r pid; do kill "$pid" 2>/dev/null; done
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
	*) return 1 ;;
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

# 一覧のパネル（`vc` がなければ、出さない。出したか否かを、戻り値で）
show_panel() {
	vc=$(find_vc) || return 1
	close_list_panels
	markdown | "$vc" show --title "$list_title" >/dev/null 2>&1
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
wait)
	# 内部用：時刻まで、壁時計で待つ（`sleep` だけだと、スリープの間が数えられない）→ 読み上げ → パネル
	target=${2:-0}
	text=${3:-}
	while :; do
		now=$(/bin/date +%s)
		remaining=$((target - now))
		[ "$remaining" -le 0 ] && break
		if [ "$remaining" -gt 5 ]; then /bin/sleep 5; else /bin/sleep "$remaining"; fi
	done
	late=$((now - target))
	sentence="${text}を実施する時間です"
	[ "$late" -gt 60 ] && sentence="遅れました。${sentence}"
	(/usr/bin/say -v Kyoko "$sentence" || /usr/bin/say "$sentence") >/dev/null 2>&1 &
	if vc=$(find_vc); then
		printf '# 時間です\n\n## %s\n\n%s に設定した Todo です。\n' "$text" "$(/bin/date -r "$target" +%H:%M)" | "$vc" show --title "Todo の時間" >/dev/null 2>&1
	fi
	wait
	;;
add)
	text=$(clean "${3:-}")
	if ! time_text=$(parse_time "${2:-}"); then
		echo "error: could not read the time \"${2:-}\" (use e.g. 15:00, 15時半, 午後3時)"
		exit 0
	fi
	if [ -z "$text" ]; then
		echo "error: the todo text is empty"
		exit 0
	fi
	epoch=$(/bin/date -j -f "%Y-%m-%d %H:%M:%S" "$(/bin/date +%Y-%m-%d) $time_text:00" +%s)
	if [ "$epoch" -le "$(/bin/date +%s)" ]; then
		echo "error: $time_text has already passed today (only today's times can be set)"
		exit 0
	fi
	if [ "$(pending | /usr/bin/wc -l | /usr/bin/tr -d ' ')" -ge "$max_items" ]; then
		echo "error: too many todos ($max_items). delete some first"
		exit 0
	fi
	/usr/bin/nohup /bin/sh "$self" wait "$epoch" "$text" >/dev/null 2>&1 </dev/null &
	/bin/sleep 0.3   # 待機プロセスが、一覧に出るまで、少し待つ
	panel=""
	show_panel || panel=" (no panel: vc not found) todos: $(summary)"
	echo "ok: added $(/bin/date -r "$epoch" +%H:%M) $text$panel"
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
	echo "error: unknown action. use add <HH:MM> \"<text>\" | list | delete \"<word>\" | delete all"
	;;
esac
exit 0
