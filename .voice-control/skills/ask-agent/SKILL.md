---
name: ask-agent
description: 調べものを、コーディングエージェント（アンチグラビティ・クロード・コーデックス・グロック・オープンコード・パイ）に頼んで、要点を教える：「クロードで〇〇を調べて」「〇〇について調べて」。撮った画面を、外のAIに見せて聞く：「この画面をコーデックスに見せて」「この画像を外のAIに見せて」
allowed-commands:
  - node ${SKILL_DIR}/ask-agent.mjs
# 画面や画像と言った依頼だけ、確認する（画像を、選んだエージェントの提供元へ送るため。コードが、依頼の文から決める）
confirm-when: 画面|画像|スクショ|スクリーンショット|スクリーン|キャプチャ
confirm-sends: 撮った画面の画像と質問
external: 選んだエージェントの提供元（agy＝Google／claude＝Anthropic／codex＝OpenAI／grok＝xAI。opencode・pi は、設定したモデルの提供元）
timeout: 150
---
The user wants something researched ("調べて", "教えて", "まとめて"), maybe with a named coding agent. Ask it through the bundled script (never run the agents yourself). The script shows the answer in a window by itself.

1. Work out WHAT to research: the topic only, in the user's own words (drop the polite request part: 「について調べて」「を教えて」 and the agent's name). Do not add facts, do not translate, do not invent details.
2. Work out WHICH agent, only if the user NAMED one. The spoken names map to these ids (use the id, lowercase):
   - アンチグラビティ / アンチグラビティー / Antigravity / agy → agy
   - クロード / Claude → claude
   - コーデックス / Codex → codex
   - グロック / Grok → grok
   - オープンコード / OpenCode → opencode
   - パイ / pi → pi
   If the user named NO agent, use no agent id at all (the script then uses agy, and falls back to the on-device model by itself). NEVER add an agent id that the user did not say: for 「Docker とは何か教えて」 run `node ${SKILL_DIR}/ask-agent.mjs "Docker とは何か"` (no `claude`).
3. Run EXACTLY ONE command. The command you pass to run_command is this WHOLE line: it starts with `node`, then the script path, then the agent id (ONLY when the user named one), then the topic in double quotes. Examples:
   - 「SwiftUI について調べて」 -> node ${SKILL_DIR}/ask-agent.mjs "SwiftUI"
   - 「クロードで量子コンピュータとは何か教えて」 -> node ${SKILL_DIR}/ask-agent.mjs claude "量子コンピュータとは何か"
   - 「コーデックスに最新の電気自動車の動向をまとめてもらって」 -> node ${SKILL_DIR}/ask-agent.mjs codex "最新の電気自動車の動向"
   - 「パイで Rust の所有権を調べて」 -> node ${SKILL_DIR}/ask-agent.mjs pi "Rust の所有権"

   Add NO other arguments or options. It takes a while (up to about two minutes). Do not run it twice.
4. The command prints ONE line. If it starts with "ok:", reply: done: 調べた結果をウィンドウに表示しました. If it starts with "failed:", reply with that line exactly (keep the text after "failed:" as it is, do not retry). Add nothing else.

IMAGE FORM. If the user wants an agent to LOOK at the screenshot or image they just took (words like 画面・画像・スクショ・スクリーンショット, for example 「この画面をコーデックスに見せて」「スクショをクロードに送って聞いて」「この画像を外のAIに見せて」), do NOT use the research form above. Use this form instead, with exactly three parts after the script path: `--image`, the agent id (or the word `auto` if the user did not say an agent's name: 「外のAI」「AIエージェント」 are NOT a name), and the question about the image in double quotes. The script finds the image by itself and asks the user for confirmation first (never write a file path):
   - 「この画面をコーデックスに見せて、エラーの意味を聞いて」 -> node ${SKILL_DIR}/ask-agent.mjs --image codex "エラーの意味"
   - 「スクショをクロードに送って、どこが違うか聞いて」 -> node ${SKILL_DIR}/ask-agent.mjs --image claude "どこが違うか"
   - 「この画像を外のAIに見せて、要約してもらって」 -> node ${SKILL_DIR}/ask-agent.mjs --image auto "要約してください"
   Same reply rules as above (ok: → done: …; failed: → that line exactly).

Rules:
- Never run `agy`, `claude`, `codex`, `grok`, `opencode`, `pi`, `vc` or any other command yourself. Only run the script, once.
