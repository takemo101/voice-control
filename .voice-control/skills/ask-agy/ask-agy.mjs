// 調べものを、Google の Antigravity CLI（`agy`）に頼んで、要点（Markdown）を、`vc show` のウィンドウに出す。
// 使い方: node ask-agy.mjs "<調べること>"   ← 使うのは、最初の引数だけ（調べること）。agy への指示の文と、安全のためのオプションは、ここで固定する（言語モデルは、変えられない）。
// 標準出力は、1 行（`ok: …` か `failed: 理由`）。答えの本文は、言語モデルを通さずに、ウィンドウへ渡す。
// 注意: 調べることの文（利用者の発話）は、agy（Google）へ送られる。このスキルを入れた人だけが、使う。
// シェルは使わない（`spawnSync` に、引数の配列を渡す）。
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const fail = (message, code = 1) => { console.log(`failed: ${message}`); process.exit(code); };

const question = (process.argv[2] ?? "").trim();
if (!question) fail("調べることが空です", 2);

// agy が入っているか（入っていなければ、入れ方を案内する。インストールは、しない）
const probe = spawnSync("agy", ["--version"], { encoding: "utf8" });
if (probe.error?.code === "ENOENT") {
  fail("agy コマンドがありません。次のコマンドで入れてください（Google 公式）：curl -fsSL https://antigravity.google/cli/install.sh | bash　入れたあと、ターミナルで agy を一度起動して、ログインしてください", 127);
}

const prompt = `次の事柄について、ウェブで調べて、日本語で、要点を Markdown の箇条書き（5〜7 点）にまとめてください。冒頭に、見出し（## ）を 1 つ付けます。前置き・挨拶・確認の質問は書かず、最後に、わかった範囲と、不確かな点を、1 行ずつ付けてください。出典の URL がわかれば、最後に「出典」として並べてください。ファイルの作成・変更、コマンドの実行は、しないでください。

調べること：${question}`;

// ファイルのない、空の作業フォルダで動かす（agy が、手元のファイルを読まない・書かない）。計画モード・サンドボックス（端末の操作を制限）で、1 回だけ答えさせる
const work = mkdtempSync(join(tmpdir(), "ask-agy-"));
try {
  const run = spawnSync("agy", ["-p", prompt, "--mode", "plan", "--sandbox", "--print-timeout", "100s"], { cwd: work, encoding: "utf8", maxBuffer: 4 * 1024 * 1024, timeout: 115_000 });
  if (run.error) fail(run.error.code === "ETIMEDOUT" ? "agy の答えが、時間内に返りませんでした（約 2 分）" : `agy を起動できません（${run.error.message}）`);
  const text = `${run.stdout ?? ""}`.trim();
  const errors = `${run.stderr ?? ""}`.trim();
  if (run.status !== 0 || !text) {
    const detail = `${errors || text}`;
    if (/log ?in|sign ?in|auth|credential|unauthori[sz]ed/i.test(detail)) fail("agy にログインしていません（ターミナルで agy を一度起動して、ログインしてください）");
    fail(text ? `agy が失敗しました（終了コード ${run.status}）：${detail.slice(0, 300)}` : `agy の答えが空でした${errors ? `：${errors.slice(0, 300)}` : ""}`);
  }
  // 答え（Markdown）は、ここで、ウィンドウに出す（言語モデルに、長い文を、そのまま写させない：小さなモデルは、要約し直したり、削ったりする）
  const show = spawnSync("vc", ["show", "--title", question.slice(0, 40)], { input: text, encoding: "utf8" });
  if (show.error || show.status !== 0) fail(`結果のウィンドウを開けません（${show.error?.message ?? show.stderr.trim().slice(0, 200)}）`);
  console.log(`ok: agy の答えを、ウィンドウに表示しました（${text.length} 文字）`);
} finally {
  rmSync(work, { recursive: true, force: true });
}
