---
name: ask-agent-image
description: 外のAI（コーデックス・クロード・グロックなど）に、撮ったものを見せて聞く：「コーデックスに見せて」「クロードに送って聞いて」「外のAIに見せて」
allowed-commands:
  - node ${SKILL_DIR}/ask-agent-image.mjs
confirm: true
external: 選んだエージェントの提供元（codex＝OpenAI／claude＝Anthropic／agy＝Google／grok＝xAI／opencode・pi＝設定したモデルの提供元。選ばなければ codex）
# 撮ったスクリーンショットがあるときだけ、選ばれる（外へ送る文は、ここから：撮った画面の画像と質問）
image: true
timeout: 150
---
The user wants an OUTSIDE AI agent to look at the screenshot they just took and answer a question about it. Ask it through the bundled script (never run the agents yourself). The script finds the screenshot by itself and shows the answer in a window.

1. Work out WHAT to ask: the question about the image, in the user's own words (drop the agent's name and the request part such as 「に見せて」「に聞いて」). If the user only says to show it, use: この画像について説明してください. Do not add facts, do not translate.
2. Work out WHICH agent. The spoken names map to these ids (use the id, lowercase):
   - コーデックス / Codex → codex
   - クロード / Claude → claude
   - アンチグラビティ / Antigravity / agy → agy
   - グロック / Grok → grok
   - オープンコード / OpenCode → opencode
   - パイ / pi → pi
   If the user did NOT say an agent's name, the id is the word `auto`. Words like 「外のAI」「AIエージェント」「外の AI」 are NOT an agent name: use `auto`. NEVER use an id that the user did not say.
3. Run EXACTLY ONE command with exactly two arguments: the agent id (or `auto`), then the question in double quotes. The command you pass to run_command is this WHOLE line, starting with `node`. Examples:
   - 「この画面をコーデックスに見せて、エラーの意味を聞いて」 -> node ${SKILL_DIR}/ask-agent-image.mjs codex "エラーの意味"
   - 「この画像について、パイに聞いて。何のグラフ？」 -> node ${SKILL_DIR}/ask-agent-image.mjs pi "何のグラフ？"
   - 「クロードにこの画面を見せて、どこを直すか聞いて」 -> node ${SKILL_DIR}/ask-agent-image.mjs claude "どこを直すか"
   - 「この画面を外の AI に見せて、要約してもらって」 -> node ${SKILL_DIR}/ask-agent-image.mjs auto "要約してください"
   - 「この画像を AI エージェントに見せて、何のアプリか聞いて」 -> node ${SKILL_DIR}/ask-agent-image.mjs auto "何のアプリか"
   Add NO file path and NO other options. Do not run it twice.
4. The command prints ONE line. If it starts with "ok:", reply: done: 画像と質問を外のエージェントに送って、答えをウィンドウに表示しました. If it starts with "failed:", reply with that line exactly (keep the text after "failed:"). Add nothing else.

Rules:
- Never run `codex`, `claude`, `agy`, `grok`, `opencode`, `pi`, `vc` or any other command yourself. Only run the script, once.
- Never write the path of an image yourself: the script uses the screenshot the user just took.
