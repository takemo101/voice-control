---
name: todo-remind
description: 今日のやること（Todo）を、時刻つきで追加・一覧・削除する。時刻になると、読み上げとパネルで知らせてくれる：「9時に会議の資料を出すのでTodoに入れて」「夕方に電話するのでTodo登録して」「Todoを見せて」「Todoを消して」「時間になったら知らせて」
timeout: 90
allowed-commands:
  - osascript ${SKILL_DIR}/todo.applescript
---
Manage the user's todo list for TODAY. Each todo has a time; at that time the Mac speaks "<todo>を実施する時間です" and shows a panel. The list lives only in memory: it disappears when the Mac restarts. Run EXACTLY ONE command for the request:

  osascript ${SKILL_DIR}/todo.applescript <action> [arguments]

Actions:
- add <time> "<todo>"    (adds a todo for a time today, then shows the list in a panel)
- run <time> "<request>" (SCHEDULES a request that another skill will carry out by itself at that time, e.g. playing music. It checks the request first, then shows the list in a panel)
- list                   (shows today's todos in a panel)
- delete "<word>"        (deletes the ONE todo whose text contains the word)
- delete all             (deletes every todo)

How to choose:
- The user wants to ADD a todo (「15時にレポート提出のTodo追加して」「午後3時にミーティングをTodoに入れて」「夜のN時にお風呂を沸かすのでTodoに登録して」) → add.
  - <time> is EITHER a time of day OR a duration counted from now. Copy the user's words EXACTLY, character by character, with no conversion and no calculation. The unit stays as said: 分後 stays 分後, 時間後 stays 時間後, and 時 stays 時 (never turn 分 or 時間 into 時). Keep the words 午前 / 午後 / 朝 / 昼 / 夕方 / 夜 as said (never swap or drop them). The script reads the words. It is the words right before に in the request, it always contains a number, and it is never a word of the todo.
    - Duration pattern (N stands for the number the user said): 「N分後に…」 → N分後 · 「N時間後に…」 → N時間後 · 「N秒後に…」 → N秒後.
    - Time-of-day pattern: 「午前N時に…」 → 午前N時 · 「夜のN時に…」 → 夜のN時 · 「朝N時に…」 → 朝N時 · 「N時に…」 → N時 · 「HH:MMに…」 → HH:MM. Copy the user's own numbers; add 分 only if the user said it.
  - "<todo>" is ONLY the thing to do, in the user's words, without the time and without the request part. 「15時にレポート提出のTodo追加して」 → "レポート提出". 「午後1時に犬の散歩をするのでTodoに入れて」 → "犬の散歩をする". Keep it short. Put it in double quotes.
  - Only today. If the user names another day (明日・あさって・来週・a date), run NO command and reply: failed: 今日の分だけ、追加できます。
- The user wants the MAC to DO something at a time, by itself (「N時に〇〇をするよう予約して」「時間になったら〇〇して」「N時に〇〇を実行するようにして」: words like 予約 · スケジュール · 時間になったら · 〜するように) → run <time> "<request>". <request> is the thing to be done, as a short sentence WITHOUT the time and WITHOUT the reservation words, in the user's words: 「N時にFinderでダウンロードフォルダを開くよう予約して」 → "Finderでダウンロードフォルダを開いて". A reminder for the USER to do something (電話する・資料を出す・「Todo」と言った) is add, not run.
- The user wants to SEE the todos (「今日のTodoを見せて」「Todoを一覧にして」「予定を教えて」) → list.
- The user wants to REMOVE one (「レポートのTodoを消して」「歯医者のTodoを削除して」「ミーティングの予定を取り消して」) → delete "<word>", where <word> is ONE distinctive noun from that todo, WITHOUT particles (の・を・に・は・が・で): 「請求書のTodoを消して」 → "請求書". 「歯医者のTodoを削除して」 → "歯医者".
- The user wants to remove EVERYTHING (「Todoを全部消して」「Todoを全て削除して」「Todoを空にして」) → delete all.

Examples:
- 「15時にレポート提出のTodo追加して」 → osascript ${SKILL_DIR}/todo.applescript add 15時 "レポート提出"
- 「午後2時半に車を洗うのでTodoに入れて」 → osascript ${SKILL_DIR}/todo.applescript add 午後2時半 "車を洗う"
- 「今日のTodoを見せて」 → osascript ${SKILL_DIR}/todo.applescript list
- 「レポートのTodoを消して」 → osascript ${SKILL_DIR}/todo.applescript delete "レポート"
- 「Todoを全部削除して」 → osascript ${SKILL_DIR}/todo.applescript delete all

Run the command once. It prints one line.
- If the line starts with "ok:", reply: done: <one short sentence in Japanese saying what was done, e.g. 15:00に「レポート提出」を追加しました>. For a "scheduled" line, say the time, the request and that a notice appears 10 seconds before it runs (closing the notice cancels it).
- If it starts with "error:", reply: failed: <the reason in Japanese>. For "already passed", tell the user that only a time later than now today can be set. For "could not read the time", ask the user to say the time again (e.g. 15時, 午後3時半). For "several todos match", ask which one (say the times). For "does not match a specific skill", tell the user that only requests that one of their skills handles can be scheduled. For "asks for confirmation", tell the user that a skill that needs confirmation cannot run on its own.
Never run any other command. Never run the command twice.
