-- 今日の Todo：追加（時間になったら、読み上げ＋パネル）・一覧・削除。使い方: osascript todo.applescript add <時刻：15:00・15時半・午後3時> "<内容>" | list | delete "<語>" | delete all
-- 受け付ける action だけを実行する（任意のコマンドは、実行しない）。本体は、同じ場所の todo.sh（言語モデルには、`osascript` だけを許可して、`sh` は、許可しない）。
-- 結果は 1 行（ok: … ・ error: …）。
use scripting additions

on run argv
	if (count of argv) is 0 then return "error: action required"
	set theAction to item 1 of argv
	if {"add", "list", "delete"} does not contain theAction then return "error: unknown action: " & theAction
	set helper to (do shell script "/usr/bin/dirname " & quoted form of (POSIX path of (path to me))) & "/todo.sh"
	set command to "/bin/sh " & quoted form of helper & " " & theAction
	-- 引数は、シェルに渡す前に、必ず、引用符でくるむ（発話は、データ：命令として、解釈させない）
	repeat with i from 2 to (count of argv)
		set command to command & " " & quoted form of (item i of argv)
	end repeat
	try
		return do shell script command
	on error errMsg
		return "error: " & errMsg
	end try
end run
