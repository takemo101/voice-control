---
name: ask-agy
description: 調べものを Antigravity（agy）に頼んで、要点を教える：「〇〇について調べて」「〇〇とは何か教えて」「〇〇の最新情報をまとめて」
allowed-commands:
  - node ${SKILL_DIR}/ask-agy.mjs
external: Google（agy コマンド経由）
timeout: 150
---
The user wants something researched ("調べて", "教えて", "まとめて"). Ask Antigravity through the bundled script (never run `agy` yourself). The script shows the answer in a window by itself.

1. Work out WHAT to research from the user's request: the topic only, in the user's own words (drop the polite request part: 「について調べて」「を教えて」). Do not add facts, do not translate, do not invent details.
2. Run EXACTLY ONE command, with ONE argument (the topic, in double quotes). The command you pass to run_command is this WHOLE line: it starts with `node`, then the script path, then the topic in double quotes. Examples:
   - 「SwiftUI について調べて」 -> node ${SKILL_DIR}/ask-agy.mjs "SwiftUI"
   - 「量子コンピュータとは何か教えて」 -> node ${SKILL_DIR}/ask-agy.mjs "量子コンピュータとは何か"
   - 「最新の電気自動車の動向をまとめて」 -> node ${SKILL_DIR}/ask-agy.mjs "最新の電気自動車の動向"

   Add NO other arguments or options. It takes a while (up to about two minutes). Do not run it twice.
3. The command prints ONE line. If it starts with "ok:", reply: done: 調べた結果をウィンドウに表示しました. If it starts with "failed:", reply with that line exactly (keep the text after "failed:" as it is, do not retry). Add nothing else.

Rules:
- Never run `agy`, `vc` or any other command yourself. Only run the script, once.
