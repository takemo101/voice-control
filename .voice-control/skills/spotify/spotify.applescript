-- Spotify デスクトップアプリを操作する。使い方: osascript spotify.applescript <action> [argument]
-- 受け付ける action だけを実行する（任意の AppleScript は、実行しない）。結果は 1 行（ok・状態の文・error: …）で返す。
use framework "Foundation"
use scripting additions

on run argv
	if (count of argv) is 0 then return "error: action required"
	set theAction to item 1 of argv
	set theArg to ""
	if (count of argv) ≥ 2 then set theArg to item 2 of argv
	-- アプリを要する action は、起動していなければ、起動して、受け付けるまで待つ（「起動して再生して」が、1 回の命令で通るように）
	if {"play", "pause", "playpause", "next", "previous", "volume-up", "volume-down", "volume", "shuffle", "repeat", "search"} contains theAction then my ensureRunning()

	if theAction is "open" then
		tell application "Spotify" to activate
		return "ok"
	else if theAction is "status" then
		-- 起動していなければ、起動しない
		if application "Spotify" is not running then return "not running"
		tell application "Spotify"
			set playerStateText to player state as text
			set vol to sound volume
			set shuf to shuffling
			if playerStateText is "stopped" then return "state: stopped | volume: " & vol & " | shuffle: " & shuf
			return "state: " & playerStateText & " | track: " & (name of current track) & " | artist: " & (artist of current track) & " | volume: " & vol & " | shuffle: " & shuf
		end tell
	else if theAction is "play" then
		tell application "Spotify" to play
		return "ok"
	else if theAction is "pause" then
		tell application "Spotify" to pause
		return "ok"
	else if theAction is "playpause" then
		tell application "Spotify" to playpause
		return "ok"
	else if theAction is "next" then
		tell application "Spotify" to next track
		return "ok"
	else if theAction is "previous" then
		tell application "Spotify" to previous track
		return "ok"
	else if theAction is "volume-up" or theAction is "volume-down" then
		tell application "Spotify"
			set v to sound volume
			if theAction is "volume-up" then set v to v + 10
			if theAction is "volume-down" then set v to v - 10
			if v > 100 then set v to 100
			if v < 0 then set v to 0
			set sound volume to v
			return "ok: volume " & v
		end tell
	else if theAction is "volume" then
		-- 0〜100 の整数だけ
		try
			set v to theArg as integer
		on error
			return "error: volume needs an integer 0-100"
		end try
		if v < 0 or v > 100 then return "error: volume needs an integer 0-100"
		tell application "Spotify" to set sound volume to v
		return "ok: volume " & v
	else if theAction is "shuffle" then
		if theArg is "on" then
			tell application "Spotify" to set shuffling to true
		else if theArg is "off" then
			tell application "Spotify" to set shuffling to false
		else
			return "error: shuffle needs on or off"
		end if
		return "ok"
	else if theAction is "repeat" then
		if theArg is "on" then
			tell application "Spotify" to set repeating to true
		else if theArg is "off" then
			tell application "Spotify" to set repeating to false
		else
			return "error: repeat needs on or off"
		end if
		return "ok"
	else if theAction is "search" then
		-- 検索の画面を開くだけ（再生はしない）。文字は、英数字以外をパーセントエンコードして、spotify:search: に付ける
		if theArg is "" then return "error: search needs a text"
		set ns to current application's NSString's stringWithString:theArg
		set enc to (ns's stringByAddingPercentEncodingWithAllowedCharacters:(current application's NSCharacterSet's alphanumericCharacterSet())) as text
		tell application "Spotify" to open location ("spotify:search:" & enc)
		return "ok"
	else
		return "error: unknown action " & theAction
	end if
end run

-- Spotify が起動していなければ、起動して（前面には出さない）、命令に答えるまで待つ（最大 約 40 秒）。
-- AppleScript の launch は、アプリが答えるまで待ち続けることがあるので、`open -g -a`（すぐ戻る）で起動する。
on ensureRunning()
	if application "Spotify" is not running then
		do shell script "/usr/bin/open -g -a Spotify"
		repeat 40 times
			if application "Spotify" is running then exit repeat
			delay 0.5
		end repeat
	end if
	-- 起動直後は、命令を受け付けないことがある：短い待ち時間で、答えるまで試す
	repeat 40 times
		try
			with timeout of 2 seconds
				tell application "Spotify" to get player state
			end timeout
			exit repeat
		end try
		delay 0.5
	end repeat
end ensureRunning
