---
name: filler-add
description: つなぎ言葉（フィラー）を、音声入力で消す語に追加・登録する：「『あのさ』をつなぎ言葉に追加して」「えーとをフィラーに足して・入れて・登録して」
allowed-commands:
  - vc fillers add
---
The user wants to add a word to the list of filler words (つなぎ言葉・フィラー) that dictation removes. The word may itself look like a filler (for example なんか or えーと): that is exactly the word to add. NEVER leave it out; the command needs the word.

1. Work out WHICH word to add: only the word itself, exactly as the user said it (drop the quotes 「」『』 and the request part: 「を、つなぎ言葉に追加して」「をフィラーに登録して」「をつなぎ言葉に足して・入れて」). Do not translate, correct or add words.
2. Run EXACTLY ONE command: `vc fillers add` then the word in double quotes. Examples:
   - 「『あのさ』をつなぎ言葉に追加して」 -> vc fillers add "あのさ"
   - 「えーっとをフィラーに登録して」 -> vc fillers add "えーっと"
   - 「you know をつなぎ言葉に追加して」 -> vc fillers add "you know"

   Add NO other arguments or options. Run it once.
3. The command prints a line starting with ✓ when it worked. Then reply: done: followed by that line's message (keep it short, in Japanese). If the command fails (an error, or a message that the word cannot be added), reply: failed: followed by the reason from the output. Do not retry.

Rules:
- Never run any other `vc` command (for example `vc fillers remove` or `vc fillers off`) and never run any other command. Only `vc fillers add`, once.
