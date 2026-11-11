---
name: image-edit
description: 撮ったスクリーンショットや、コピーした画像を加工して保存する：「右半分を切り抜いて」「横幅を800にして」「半分の大きさにして」「右に回転して」「JPEGに変換して」「背景を消して」「コピーした画像を回転して」
allowed-commands:
  - vc image
# 撮ったスクリーンショットか、コピーした画像があるときだけ、選ばれる（どちらを加工するかは、コードが決める）
image: any
---
Edit an image and save the result as a file: the screenshot the user just took, or the image they copied (the command chooses which one by itself; you never name it). Run one command that starts with `vc image` for EACH operation the user asked for, in the order the user said them (usually just one; at most 3). Each command works on the result of the previous one, so never repeat an operation.

1. Pick the operations from the request and write each whole command:
   - cut out part (切り抜き・トリミング): `vc image crop <part>` where part is ONE of these words:
     - 右半分 / 右側の半分 -> vc image crop right-half
     - 左半分 / 左側の半分 -> vc image crop left-half
     - 上半分 / 上の半分 -> vc image crop top-half
     - 下半分 / 下の半分 -> vc image crop bottom-half
     - 真ん中 / 中央 -> vc image crop center
     - 真四角 / 正方形 / 四角く -> vc image crop square
     Only for another part (for example 右の3分の1), use fractions between 0 and 1 of the whole image: `vc image crop --left F --top F --width F --height F`, writing only the options that are needed.
   - change the size (サイズ変更・リサイズ): `vc image resize --width <pixels>` when the user says a width (横・幅・px), or `vc image resize --percent <number>` for a ratio.
     - 横幅を800にして -> vc image resize --width 800
     - 半分の大きさにして -> vc image resize --percent 50
     - 2倍にして -> vc image resize --percent 200
   - turn (回転): `vc image rotate <degrees>` where degrees is ONE number.
     - 右に回転 / 右へ回して / 時計回り -> vc image rotate 90
     - 左に回転 / 左へ回して / 反時計回り -> vc image rotate 270
     - 上下逆さま / 逆さまに / 180度 -> vc image rotate 180
   - change the file format (形式変換・変換): `vc image convert <format>` where format is ONE word: jpg, png or heic. Never write the three words together.
     - JPEG / JPG / ジェイペグ に変換 -> vc image convert jpg
     - PNG / ピング にして -> vc image convert png
     - HEIC / ヒーク にして -> vc image convert heic
   - remove the background (背景を消す・背景除去・背景を透明に・人物だけ切り抜く): `vc image remove-background` (no arguments). It keeps the main subject and makes the rest transparent. Use it ONLY when the request talks about the background (背景) or about keeping the subject (人物・被写体だけ); a part of the picture (右半分...) is `crop`.
     - 背景を消して / 背景を透明にして / 背景を削除して -> vc image remove-background
     - 人物だけ切り抜いて / 被写体だけ残して -> vc image remove-background
2. Each command prints "saved: <path> (<width>x<height>, <format>)". When all are done, reply: done: <path> に保存しました (use the path printed by the LAST command).
3. If it prints an error, reply: failed: <the error, in Japanese>. Do not try anything else.

Rules:
- Never use another command, never write a file name or a folder (the command decides where to save). Never name the image to edit (no `--from`): the command chooses it.
- Run a command only for an operation the user actually said. Do not add operations of your own.
- One command per tool call: never join commands with `&&`, `;` or `|` (there is no shell). For two operations, call the tool twice.
