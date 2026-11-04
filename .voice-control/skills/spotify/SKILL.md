---
name: spotify
description: Spotify の操作：起動する・開く・再生・一時停止・次の曲・前の曲・音量・今流れている曲は何か（曲名を教える）・検索・シャッフル。「音楽をかけて」「曲を流して」も
allowed-commands:
  - osascript .voice-control/skills/spotify/spotify.applescript
---
Control the Spotify desktop app. Run EXACTLY ONE command for the request:

  osascript .voice-control/skills/spotify/spotify.applescript <action> [argument]

Use only these actions:
- play | pause | playpause (toggle) | next | previous
- volume-up | volume-down | volume <0-100>
- shuffle on|off | repeat on|off
- status   (prints the player state, track, artist, volume)
- search "<text>"   (opens the Spotify search page; use only the words the user said; does not start playback)
- open   (launches Spotify if it is not running, and brings it to the front)

Which action for which request:
- launch the app / open it / bring it to the front (起動して・開いて・立ち上げて) → open. There is NO action named start or launch. Never run `open -a` yourself: the script launches Spotify when needed.
- play music / put on a song / resume (再生して・かけて・流して) → play. stop / pause → pause. "toggle play and pause" → playpause.
- next song / skip → next. previous song / go back → previous.
- louder / volume up → volume-up. quieter / volume down → volume-down. "volume 50" → volume 50.
- what is playing now / which song → status. search for something → search "<text>".

The command prints one line. If it starts with "error:", reply: failed: <the message>.
After status, tell the user the state, track and artist in Japanese.
Otherwise reply: done: <one short sentence in Japanese>.
