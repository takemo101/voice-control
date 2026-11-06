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
	if {"play", "pause", "playpause", "next", "previous", "volume-up", "volume-down", "volume", "mute", "shuffle", "repeat", "search"} contains theAction then my ensureRunning()

	if theAction is "open" then
		if application "Spotify" is running then
			tell application "Spotify" to activate
		else
			-- 起動していないとき、AppleScript の activate は、アプリが答えるまで待ち続けて、vc の 30 秒の上限に掛かることがある。`open -a` は、すぐ戻る
			do shell script "/usr/bin/open -a Spotify"
		end if
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
	else if theAction is "announce" then
		-- 今の曲を、日本語で読み上げる（`say`）。起動していなければ、起動しない。話す文は、ここで組み立てる（言語モデルは、文を作らない）
		if application "Spotify" is not running then return my speak(my buildAnnouncement("not running", "", ""))
		tell application "Spotify"
			set playerStateText to player state as text
			if playerStateText is "stopped" then return my speak(my buildAnnouncement("stopped", "", ""))
			set trackName to name of current track
			set artistName to artist of current track
		end tell
		return my speak(my buildAnnouncement(playerStateText, trackName, artistName))
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
		-- 10 ずつ動かすだけ。数を渡されたら、黙って 10 だけ動かさず（「最大まで」が、10 だけ上がって、成功に見える）、正しい使い方を返す
		if theArg is not "" then return "error: " & theAction & " takes no argument (it changes the volume by 10). To set a level use: volume <0-100> (volume max = 100, volume min = 0)"
		tell application "Spotify"
			set v to sound volume
			if theAction is "volume-up" then set v to v + 10
			if theAction is "volume-down" then set v to v - 10
			if v > 100 then set v to 100
			if v < 0 then set v to 0
			set sound volume to v
			return "ok: volume " & v
		end tell
	else if theAction is "mute" then
		-- 音量を 0 にする（Spotify だけ。システムの消音ではない）
		tell application "Spotify" to set sound volume to 0
		return "ok: volume 0"
	else if theAction is "volume" then
		-- 0〜100 の整数。max は 100、min は 0
		if theArg is "max" then set theArg to "100"
		if theArg is "min" then set theArg to "0"
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
	else if theAction is "like" then
		return my toggleLike()
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

-- 読み上げる文。state：`playing`・`paused`・`stopped`・`not running`。曲名・アーティスト名は、Spotify の文字をそのまま使う（空なら、触れない）。
on buildAnnouncement(stateText, trackName, artistName)
	if stateText is "not running" then return "Spotify は、起動していません"
	if stateText is "stopped" then return "いまは、再生していません"
	set subject to trackName
	if artistName is not "" then set subject to artistName & " の " & trackName
	if stateText is "playing" then return "今流れているのは、" & subject & " です"
	return "一時停止中の曲は、" & subject & " です"
end buildAnnouncement

-- 話す（`say`。日本語の声 Kyoko。なければ、既定の声）。文は、`quoted form of` で、1 つの引数にする（シェルを通しても、曲名の文字が、コマンドにならない）。終わるまで待たない。
on speak(sentence)
	do shell script "(/usr/bin/say -v Kyoko " & quoted form of sentence & " || /usr/bin/say " & quoted form of sentence & ") >/dev/null 2>&1 &"
	return "ok: spoke: " & sentence
end speak

-- 今の曲の「いいね」（Liked Songs への追加）を切り替える。Spotify の AppleScript には、いいねの命令がない（`starred` は、読み取り専用）ので、アプリのショートカット ⌥⇧B を送る。
-- **切り替え（トグル）**：すでに追加済みなら、解除になる（状態は、読めない）。Spotify を、一瞬、前面にして、キーを送り、元のアプリを前面に戻す。
-- 要る許可：アクセシビリティ（キーを送る）と、System Events の操作（オートメーション）。Spotify が起動していなければ、起動しない（曲がないので、何もしない）。
on toggleLike()
	if application "Spotify" is not running then return "error: Spotify is not running"
	set trackText to ""
	try
		tell application "Spotify"
			if (player state as text) is "stopped" then return "error: no track is loaded"
			set trackText to (name of current track) & " / " & (artist of current track)
		end tell
	on error
		return "error: no current track"
	end try
	set previousApp to ""
	try
		tell application "System Events" to set previousApp to name of first application process whose frontmost is true
	end try
	try
		tell application "Spotify" to activate
		delay 0.5
		tell application "System Events" to key code 11 using {option down, shift down}
		delay 0.3
	on error errMsg
		my restoreFront(previousApp)
		return "error: could not send the shortcut (" & errMsg & "). Allow Accessibility and Automation (System Events) for the terminal app."
	end try
	my restoreFront(previousApp)
	return "ok: toggled like for " & trackText & " (if it was already liked, it is now removed)"
end toggleLike

-- 元のアプリを前面に戻す（Spotify 自身・分からないときは、何もしない）。
on restoreFront(appName)
	if appName is not "" and appName is not "Spotify" then
		try
			tell application appName to activate
		end try
	end if
end restoreFront

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
