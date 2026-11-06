// ブラウザで、サイトの検索ページを開く：「Amazon でマウスを検索」「Google で〇〇」「YouTube で〇〇」。
// 使い方: node web-search.mjs <サイト> "<検索する言葉>"   ← 使うのは、最初の 2 つの引数だけ。URL は、ここで、決まった形（https の固定の元 + 言葉のエンコード）から作る（言語モデルは、URL を作らない：エンコードの間違い・別のサイトへの誘導を防ぐ）。
// 標準出力は、1 行（`ok: …` か `failed: 理由`）。ブラウザは、いつも使っているもの（`open`）。シェルは使わない。
// 注意: 検索する言葉（利用者の発話）は、選んだサイトへ送られる（ブラウザが開く）。このスキルを入れた人だけが、使う。
import { spawnSync } from "node:child_process";

const fail = (message, code = 1) => { console.log(`failed: ${message}`); process.exit(code); };

/** サイトの表。`url`：言葉を、エンコードして、差し込む。`names`：サイトの呼び名（小文字。全角・カタカナも）。足すときは、1 行。 */
const SITES = {
  google: { label: "Google", url: (q) => `https://www.google.com/search?q=${q}`, names: ["google", "グーグル", "ぐーぐる", "ググる", "ブラウザ", "browser", "web", "ウェブ", "ネット"] },
  amazon: { label: "Amazon", url: (q) => `https://www.amazon.co.jp/s?k=${q}`, names: ["amazon", "アマゾン", "あまぞん", "amazon.co.jp"] },
  youtube: { label: "YouTube", url: (q) => `https://www.youtube.com/results?search_query=${q}`, names: ["youtube", "ユーチューブ", "ようつべ", "ゆーちゅーぶ", "動画"] },
  rakuten: { label: "楽天市場", url: (q) => `https://search.rakuten.co.jp/search/mall/${q}/`, names: ["rakuten", "楽天", "楽天市場", "らくてん"] },
  yahoo: { label: "Yahoo! JAPAN", url: (q) => `https://search.yahoo.co.jp/search?p=${q}`, names: ["yahoo", "ヤフー", "やふー", "yahoo!"] },
  wikipedia: { label: "Wikipedia", url: (q) => `https://ja.wikipedia.org/w/index.php?search=${q}`, names: ["wikipedia", "ウィキペディア", "ウィキ", "wiki"] },
  maps: { label: "Google マップ", url: (q) => `https://www.google.com/maps/search/${q}`, names: ["maps", "map", "マップ", "地図", "googleマップ", "グーグルマップ"] },
};

const siteArg = (process.argv[2] ?? "").trim().toLowerCase();
// 言葉：制御文字を落とし、空白を整え、長さを制限する（URL に入れるので）
const query = (process.argv[3] ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();
if (!query) fail("検索する言葉が空です", 2);
if (query.length > 200) fail("検索する言葉が長すぎます（200 文字まで）", 2);

const key = Object.keys(SITES).find((k) => k === siteArg || SITES[k].names.some((n) => n.toLowerCase() === siteArg));
if (!key) fail(`知らないサイトです「${siteArg.slice(0, 30)}」（${Object.keys(SITES).join("・")}）`, 2);

const site = SITES[key];
const url = site.url(encodeURIComponent(query));
const opened = spawnSync("open", [url], { encoding: "utf8" });
if (opened.error || opened.status !== 0) fail(`ブラウザを開けません（${opened.error?.message ?? opened.stderr.trim().slice(0, 200)}）`);
console.log(`ok: ${site.label} で「${query}」を検索しました`);
