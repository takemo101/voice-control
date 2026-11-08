---
name: screen-ask
description: 撮ったスクリーンショットの画像について、Mac の中のモデルで答える：「この画像の文字を書き出して」「この画像は何？」「この画面を説明して」「この画面の文字を読んで」「この表をマークダウンにして」
allowed-commands:
  - vc see
timeout: 180
---
Answer the user's request about the screenshot they just took. The command looks at the image itself (on this Mac) and shows the answer in a window.

The request can be anything about the image: read the text, explain it, translate it, summarize it, turn a table into Markdown, answer a question. Whatever it is, you do NOT do it yourself: the command does it.

1. Run EXACTLY ONE command, with NO arguments, exactly like this:
   vc see
   Do not add any text, quote or option. Do not run it twice.
2. If the result says the answer is shown in a window, reply: done: 結果をウィンドウに表示しました
3. If the command printed an error (for example there is no screenshot), reply: failed: <the error, in Japanese>. Do not try anything else.

Rules:
- Never describe, translate or convert anything yourself: you cannot see the image. Your first action is always the tool call `vc see`.
