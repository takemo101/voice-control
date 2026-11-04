---
name: voice-control-skill-author
description: voice-control（vc）用のスキルを作る・直す。~/.voice-control/skills/<name>/SKILL.md を書き、vc skills list と vc run --dry-run で確かめる。「スキルを作って」「vc のスキルを追加」と頼まれたときに使う。
---

# voice-control のスキルを作る

`vc run "<依頼>"` は、**Tiny-Jev** が、有効なスキルの `description` から、呼ぶスキルを選び、**Apple の言語モデル**（FoundationModels）が、スキルの本文と依頼文を読んで、`run_command` という道具で、コマンドを実行する。スキルは `~/.voice-control/skills/<name>/SKILL.md` に置く（`VC_HOME` で、`~/.voice-control` を変えられる）。

2 つの読み手がいる。**書き方が違う**ので、混ぜない。

| 読み手 | 読む場所 | 書き方 |
|---|---|---|
| Tiny-Jev（選ぶ） | フロントマターの `description` だけ | 日本語。短く。人が頼む言い方に近く。ほかのスキルと、言葉を分ける |
| Apple のモデル（実行する） | 本文 | **英語**。番号つきの手順。実際のコマンドを、そのまま書く |

## 手順

1. **何を実行するか**を決める。コマンドを、先に、自分で端末で動かして、確かめる（`agent-desktop` を使うなら、`snapshot` の出力も見る）。
2. **許可するコマンドを、最小にする**（下の `allowed-commands`）。
3. `~/.voice-control/skills/<name>/SKILL.md`（どこでも使う）か、`<プロジェクトのルート>/.voice-control/skills/<name>/SKILL.md`（そのプロジェクトで vc を起動したときだけ。同名はプロジェクトが勝つ。使うには、そのプロジェクトで `vc skills trust`）を書く（下の雛形）。`<name>` は、英小文字・数字・ハイフン（40 文字まで）で、フロントマターの `name` と、**同じ**にする。
4. `vc skills list` で、読み込めたかを見る（不正なものは、理由つきで、一覧の下に出る）。
5. `vc run "<依頼の例>" --dry-run` で、(a) Tiny-Jev が、このスキルを選ぶか、(b) どんなコマンドを実行しようとするか、を見る。**dry-run はコマンドを実行しない**ので、モデルは出力を見られない（途中の手順は、推測になる）。
6. 安全な状態で、`vc run "<依頼の例>"` を、本番で実行する。実行するコマンドと結果は、画面に出る。
7. **選ばれ方**を確かめる：言い換えを 5 通り以上と、関係のない発話（会話）を 3 つ試す。ほかのスキルと取り違えるなら、`description` の言葉を分ける。
8. 使わなくするには、削除ではなく `vc skills disable <name>`（選択肢から外れる。`enable` で戻る）。

## 雛形

```markdown
---
name: open-app
description: アプリを開く・起動する・前面に出す
allowed-commands:
  - open
---
Open the application the user named.
1. Run: open -a "<App name>"   (use the official app name, e.g. Safari, Calculator)
2. If the command fails, check the name and try once more.
Then reply done.
```

### フロントマター

| キー | 必須 | 内容 |
|---|---|---|
| `name` | ○ | ディレクトリ名と同じ。英小文字・数字・ハイフン |
| `description` | ○ | Tiny-Jev が読む。200 文字まで（**60 字ほどに収める**） |
| `result` | | `markdown-note` なら、最後の返事（Markdown）を、ファイルにして開く。本文では「Markdown の本文だけを返す（done: を付けない）」と書く。例：`.voice-control/skills/clipboard-note` |
| `allowed-commands` | ○ | 実行してよいコマンド（**許可リスト**）。リスト（`- open`）か `[open, say]`。**先頭のトークン列**が一致したものだけ実行する（前方一致）：`agent-desktop` ならどの引数でも、`agent-desktop click` なら click だけ |
| `confirm` | | `true` なら、実行の前に、必ず確認する |

`allowed-commands` の規則：
- コマンド名だけ（パス不可。`/bin/rm` は不可。`*` も不可）。引数の一部（`agent-desktop snapshot`）で、さらに絞れる。**できるだけ絞る**（`agent-desktop` 全体より `agent-desktop click`）。
- トークンの中の `*` は、そのトークンの中で任意の文字列に一致する（`agent-desktop click @a*`、`open -a *.app`）。`*` だけのトークンは、任意の 1 トークン。トークンをまたぐ `*`・完全一致・正規表現はない。
- Claude Code の形（`Bash(open -a *)`）も読める（`Bash` だけ）。**意味は違う**：Claude Code の `allowed-tools` は「確認なしで使える」の承認で、こちらは「これ以外は実行しない」の制限。`*` のない項目は、前方一致（Claude Code は完全一致）。詳細は `docs/skills.md` の「Claude Code との違い」。
- **許可できない**（読み込まれない）：`sh bash zsh dash fish ksh csh tcsh env xargs sudo su doas eval exec nohup command builtin`。シェルなどを通すと、許可の意味がなくなるため。`agent-desktop --force` も、実行時に拒否される。
- `osascript`・`python`・`node` など、**任意のコードを実行できるもの**は、許可しない。必要なら、利用者に、理由を説明して、確認してもらう。
- スクリプトを同梱するときは、`allowed-commands` と本文で、スクリプトの場所を **`${SKILL_DIR}`**（そのスキルのディレクトリ。`vc` が、読み込むとき、絶対パスに置き換える）で書く。例：`osascript ${SKILL_DIR}/run.applescript`。相対パスで書くと、グローバルに置いたとき（起動した場所が違うとき）、見つからず失敗する。
- コマンドは、**シェルなし**で実行される：パイプ・リダイレクト・`&&`・`;`・`$(…)`・グロブ（`*.txt` の展開）は、使えない。1 回に、1 コマンド。

## description の書き方（Tiny-Jev）

- 「ユーザーが何を頼むか」を、短い日本語で。実装の説明ではない。
  - 良い：`アプリを開く・起動する・前面に出す`
  - 悪い：`open コマンドでアプリケーションを起動するスキル`
- 言い換えを、「・」で並べてよい（開く・起動する・立ち上げる）。
- ほかのスキルと、**同じ言葉を使わない**（「開く」が 2 つのスキルにあると、取り違える）。
- 「どれでもない」（会話・独り言）が選ばれる余地を、残す：広すぎる説明（「パソコンを操作する」）は、会話まで、引き寄せる。
- 選択肢が 32 個を超えると、勝ち抜き戦になり、確率が薄まる。**スキルを、増やしすぎない**。

## 本文の書き方（Apple のモデル）

測定で分かったこと（自作ウィンドウ・各 4 回）：
- **英語で書く**。日本語の指示だと、道具を呼ばずに、文章で答えることが多かった（6 回中 5 回）。
- **コマンドを、そのまま書く**。`agent-desktop snapshot -i --app <App>` のように。
- **出力の形と、写す部分を、例で示す**。`agent-desktop snapshot` の出力は、vc が短くして、`@a1:e7 [button] Save` の行（`@a1` は、vc が付ける短い別名で、実行の直前に、本物の参照に戻す）にして返す。`click` に渡すのは、`@a1:e7`（`@` で始まる参照）で、名前ではない。例がないと、モデルは、`click Settings` と名前を渡して、失敗した。
- 手順は、**番号つきで、短く**（モデルの入力に、約 4000 トークンの上限がある。本文は、300 語以内）。
- **作らせない**：入力する文字は、「ユーザーが言った文字だけ」と、書く。文字は、かぎ括弧で囲んで話す前提にすると、取り出しやすい（「ねこ」と入れて）。
- 終わり方を決める：`Then reply done.`
- 1 回に実行できるコマンドは、15 個まで。1 コマンドは、30 秒まで。

### agent-desktop を使うスキルの要点

- `agent-desktop snapshot -i --app <App>`：操作できる要素を、`@参照 [役割] 名前` の行で返す。続けて、`agent-desktop click @参照`・`agent-desktop type @参照 "文字"`・`agent-desktop press cmd+s --app <App>`・`agent-desktop scroll @参照 --direction down`。
- アプリを開くのは、`agent-desktop launch` ではなく、`open -a "<App>"`（`launch` は、アプリ一覧に壊れた記録があると、TIMEOUT する）。
- アプリによっては、画面を読めない（`WINDOW_NOT_FOUND`。Electron 系のアプリ：Spotify など）。そのときは、キー操作（`press`）で代わりにする手順を、書く。
- メニューバー・ダイアログの中は、`snapshot -i` に出ない（`--surface menubar` などが要る）。
- `agent-desktop` 以外のコマンド（`open`・`say`・`pbcopy`・`shortcuts run` など）も、`allowed-commands` に書けば、使える。

## チェックリスト

- [ ] `name` が、ディレクトリ名と同じ（英小文字・数字・ハイフン）
- [ ] `description` は、日本語で短く、依頼の言い方に近い
- [ ] `allowed-commands` は、最小（できれば、サブコマンドまで）。禁止のコマンド・任意コードのコマンドを、含まない
- [ ] スクリプトを同梱するなら、場所は `${SKILL_DIR}` で書いた（相対パス・個人の絶対パスにしていない）。グローバルに置いても、別のディレクトリから `vc run --dry-run` で、コマンドが、そのスキルの場所の絶対パスになった
- [ ] 本文は、英語・番号つき・実際のコマンド・出力の例・`@参照` の写し方
- [ ] `vc skills list` で、読み込めた（問題が出ていない）
- [ ] `vc run "<例>" --dry-run` で、選ばれた。関係のない発話では、選ばれなかった
- [ ] 本番の実行で、期待どおりに動いた（コマンドと結果が、画面に出る）
