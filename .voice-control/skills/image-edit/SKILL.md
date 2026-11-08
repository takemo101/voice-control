---
name: image-edit
description: 撮ったスクリーンショットの画像を加工して保存する：「右半分を切り抜いて」「横幅を800にして」「半分の大きさにして」「右に回転して」「JPEGに変換して」「PNGにして」
allowed-commands:
  - vc image
---
Edit the screenshot the user just took and save the result as a file. Run EXACTLY ONE command that starts with `vc image`.

1. Pick the operation from the request and write the whole command:
   - cut out part (切り抜き・トリミング): `vc image crop <part>` where part is ONE of these words:
     - 右半分 / 右側の半分 -> vc image crop right-half
     - 左半分 / 左側の半分 -> vc image crop left-half
     - 上半分 / 上の半分 -> vc image crop top-half
     - 下半分 / 下の半分 -> vc image crop bottom-half
     - 真ん中 / 中央 -> vc image crop center
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
2. The command prints "saved: <path> (<width>x<height>, <format>)". Reply: done: <path> に保存しました (use the path it printed).
3. If it prints an error, reply: failed: <the error, in Japanese>. Do not try anything else.

Rules:
- Run only ONE `vc image` command. Never use another command, never write a file name or a folder (the command decides where to save).
