---
name: spotify
description: Spotify の操作：起動する・開く・再生・一時停止・次の曲・前の曲・音量（上げる・下げる・最大・最小・ミュート・数値）・今流れている曲は何か（曲名を教える）・検索・シャッフル。「音楽をかけて」「曲を流して」も
allowed-commands:
  - osascript .voice-control/skills/spotify/spotify.applescript
---
Control the Spotify desktop app. Run EXACTLY ONE command for the request:

  osascript .voice-control/skills/spotify/spotify.applescript <action> [argument]

Use only these actions:
- play | pause | playpause (toggle) | next | previous
- volume-up | volume-down   (change the volume by 10 only; they take NO argument) | volume <1-100> (e.g. volume 100, volume 30) | mute (sets the volume to 0)
- shuffle on|off | repeat on|off
- status   (prints the player state, track, artist, volume)
- search "<text>"   (opens the Spotify search page; use only the words the user said; does not start playback)
- open   (launches Spotify if it is not running, and brings it to the front)

Which action for which request:
- mute / silence / volume to zero (ミュートして・音量を0にして・音量をゼロにして・最小まで下げて) → mute
- launch the app / open it / bring it to the front (起動して・開いて・立ち上げて) → open. There is NO action named start or launch. Never run `open -a` yourself: the script launches Spotify when needed.
- play music / put on a song / resume (再生して・かけて・流して) → play. stop / pause → pause. "toggle play and pause" → playpause.
- next song / skip → next. previous song / go back → previous.
- a little louder / quieter (no target level) → volume-up / volume-down (no argument).
- a target level → volume <N>. NEVER volume-up/volume-down with a number.
  - maximum / as loud as possible / 最大・最大まで・100まで → volume 100
  - minimum / lowest / zero / mute / 最小・最小まで・ゼロ・0にして・ミュート → mute
  - half / 半分 → volume 50.  "volume 50" / 50にして / 50まで → volume 50
  - Examples: 「ミュートして」→ mute / 「音量を半分にして」→ volume 50 / 「音量を最大にして」→ volume 100. The action and the number are two separate words: `volume 50` (never `volume-50`).
- status: ONLY when the user asks a QUESTION about the current state (what is playing? which song? how loud is it now?). It only READS: never use it for a command such as mute / volume / play / next.
- search for something → search "<text>".

The command prints one line. If it starts with "error:", reply: failed: <the message>.
After status, tell the user the state, track and artist in Japanese.
Otherwise reply: done: <one short sentence in Japanese>.
