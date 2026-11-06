---
name: web-search
description: ブラウザでサイトを指定して検索する：「Amazonで〇〇を検索」「Googleで〇〇」「YouTubeで〇〇の動画」「楽天で〇〇」「Wikipediaで〇〇を調べて」「ヤフーで〇〇」「地図で〇〇」
allowed-commands:
  - node ${SKILL_DIR}/web-search.mjs
---
Open a site's search page in the user's browser with the search words.

1. Decide the SITE and the SEARCH WORDS from the user's request.
   - SITE: one of `google`, `amazon`, `youtube`, `rakuten`, `yahoo`, `wikipedia`, `maps`. Amazon / アマゾン → amazon. Google / グーグル / ググって / 「ブラウザで」 / no site named → google. YouTube / ユーチューブ / 動画 → youtube. 楽天 → rakuten. ヤフー → yahoo. ウィキペディア → wikipedia. 地図 / マップ → maps.
   - SEARCH WORDS: only the things to search for, in the user's own words (drop the site name and the request part such as 「を検索して」「で探して」「の動画」). Do not translate, do not add words.
2. Run EXACTLY ONE command: the whole line starts with `node`, then the script path, then the site, then the search words in double quotes. Examples:
   - 「Amazonでワイヤレスマウスを検索して」 -> node ${SKILL_DIR}/web-search.mjs amazon "ワイヤレスマウス"
   - 「Googleで明日の天気を検索」 -> node ${SKILL_DIR}/web-search.mjs google "明日の天気"
   - 「YouTubeでSwiftUIのチュートリアルを探して」 -> node ${SKILL_DIR}/web-search.mjs youtube "SwiftUI チュートリアル"
   - 「楽天で加湿器を検索」 -> node ${SKILL_DIR}/web-search.mjs rakuten "加湿器"
   Add NO other arguments or options. Do not run it twice.
3. The command prints ONE line. If it starts with "ok:", reply: done: <the text after "ok:">. If it starts with "failed:", reply with that line exactly. Add nothing else.

Rules:
- Never build a URL yourself, never run `open` or any other command. Only run the script, once.
