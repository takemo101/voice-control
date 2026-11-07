// 調べものを、コーディングエージェントの CLI（agy・claude・codex・grok・opencode・pi）に頼んで、要点（Markdown）を、`vc show` のウィンドウに出す。
// 使い方: node ask-agent.mjs "<調べること>"            ← エージェントを選ばない：agy（Antigravity）
//         node ask-agent.mjs <エージェント> "<調べること>"   ← <エージェント> は、agy・claude・codex・grok・opencode・pi のどれか
// エージェントへの指示の文と、安全のためのオプション（読むだけ・ファイルを作らない・空の作業フォルダ）は、ここで固定する（言語モデルは、変えられない）。
// 標準出力は、1 行（`ok: …` か `failed: 理由`）。答えの本文は、言語モデルを通さずに、ウィンドウへ渡す。
// 注意: 調べることの文（利用者の発話）は、選んだエージェントの提供元（Google・Anthropic・OpenAI・xAI・opencode と pi に設定したモデルの提供元）へ送られる。このスキルを入れた人だけが、使う。
// 使うエージェント（選ばなければ agy。どれでも同じ）が、この Mac に入っていなければ、この Mac の Apple のモデル（`fm respond`）で答える（Web は見ない。発話は、この Mac の外へ出ない）。答えの先頭に、そのことを書く。
// 代わりは、`fm` だけ（外の別のエージェントでは、代わりをしない：送り先が、気づかないうちに変わらないように）。入っていて失敗したとき（ログインしていない・時間切れなど）は、代わりをせず、失敗にする。
// シェルは使わない（`spawnSync` に、引数の配列を渡す）。
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const fail = (message, code = 1) => { console.log(`failed: ${message}`); process.exit(code); };

// 引数：1 つなら、調べること。2 つなら、エージェント・調べること
const args = process.argv.slice(2);
if (args.length > 2) fail("引数が多すぎます（エージェント〔省略できる〕と、調べること）", 2);
const requested = args.length === 2 ? args[0].trim().toLowerCase() : undefined;
const question = (args[args.length - 1] ?? "").trim();
if (!question) fail("調べることが空です", 2);

// 使うモデル（agy だけ）。`agy models` の名前。既定は Gemini 3.8 Flash（Medium）。環境変数 ASK_AGENT_AGY_MODEL で替えられる。オプションの注入を防ぐため、英小文字・数字・`.`・`-` だけ（先頭は、英数字）
const AGY_DEFAULT_MODEL = "gemini-3.8-flash-medium";
const agyModel = (process.env.ASK_AGENT_AGY_MODEL ?? "").trim() || AGY_DEFAULT_MODEL;
if (!/^[a-z0-9][a-z0-9.-]*$/.test(agyModel)) fail(`ASK_AGENT_AGY_MODEL「${agyModel.slice(0, 40)}」は使えません（agy models の名前：英小文字・数字・. と - だけ）`, 2);

const askWeb = `次の事柄について、ウェブで調べて、日本語で、要点を Markdown の箇条書き（5〜7 点）にまとめてください。冒頭に、見出し（## ）を 1 つ付けます。前置き・挨拶・確認の質問は書かず、最後に、わかった範囲と、不確かな点を、1 行ずつ付けてください。出典の URL がわかれば、最後に「出典」として並べてください。ファイルの作成・変更、コマンドの実行は、しないでください。\n\n調べること：${question}`;
const askKnowledge = `次の事柄について、あなたが知っている範囲で、日本語で、要点を Markdown の箇条書き（5〜7 点）にまとめてください。冒頭に、見出し（## ）を 1 つ付けます。前置き・挨拶・確認の質問は書かず、最後に、わかった範囲と、不確かな点を、1 行ずつ付けてください。Web は見られません。知らないこと・自信のないことは、わからないと書き、作り話をしないでください。ファイルの作成・変更、コマンドの実行は、しないでください。\n\n調べること：${question}`;

// エージェントごとの呼び方。`args(dir, outFile)` は、**空の作業フォルダ** `dir` で動かす前提の引数。`outFile` は、答えをファイルへ出すもの（codex）だけが使う。
// どれも、1 回だけ答えさせて終わる・読むだけ（ファイルの作成・変更、コマンドの実行をさせない）。`web: false` は、Web を見られない（答えの先頭に、そう書く）。
const AGENTS = {
  agy: {
    label: "Antigravity（agy）", web: true,
    args: () => ["-p", askWeb, "--model", agyModel, "--mode", "plan", "--sandbox", "--print-timeout", "100s"],
  },
  claude: {
    label: "Claude Code（claude）", web: true,
    // 使える道具を、Web の 2 つ（検索・取得）だけにする：ファイル・端末の道具は、無い。許可の確認（対話）が出ないよう、dontAsk
    args: () => ["-p", askWeb, "--tools", "WebSearch,WebFetch", "--allowedTools", "WebSearch,WebFetch", "--permission-mode", "dontAsk", "--no-session-persistence", "--output-format", "text"],
  },
  codex: {
    label: "Codex（codex）", web: true, answerFile: true,
    // read-only のサンドボックス・Web 検索あり（`--search` は、`exec` の前に置く、全体のオプション）・履歴を残さない。答えは、最後のメッセージだけを、ファイルへ（途中の経過を、混ぜない）
    args: (dir, out) => ["--search", "exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "--color", "never", "-C", dir, "-o", out, askWeb],
  },
  grok: {
    label: "Grok（grok）", web: true,
    // plan モード（読むだけ）・サンドボックス。Web 検索は、既定で有効
    args: (dir) => ["-p", askWeb, "--cwd", dir, "--permission-mode", "plan", "--output-format", "plain"],
  },
  opencode: {
    label: "OpenCode（opencode）", web: true,
    // plan エージェント（読むだけ：ファイルの変更・端末の実行は、確認が要る／拒否）。`run` は、1 回だけ答えて終わる
    args: () => ["run", "--agent", "plan", askWeb],
  },
  pi: {
    label: "pi（pi）", web: false,
    // 道具を、すべて無効（ファイル・端末に触れない）。Web の道具は、無いので、モデルの知識の範囲で答える
    args: () => ["-p", askKnowledge, "--no-tools", "--no-session", "--no-extensions", "--no-skills", "--no-context-files"],
  },
};
const IDS = Object.keys(AGENTS).join("・");
const DEFAULT_AGENT = "agy";   // 選ばなかったときのエージェント

const showWindow = (markdown) => {
  const show = spawnSync("vc", ["show", "--title", question.slice(0, 40)], { input: markdown, encoding: "utf8" });
  if (show.error || show.status !== 0) fail(`結果のウィンドウを開けません（${show.error?.message ?? show.stderr.trim().slice(0, 200)}）`);
};

const isInstalled = (name) => { const p = spawnSync(name, ["--version"], { encoding: "utf8" }); return !p.error; };

if (requested !== undefined && !AGENTS[requested]) fail(`「${requested.slice(0, 20)}」は、使えるエージェントではありません（${IDS}）`, 2);
let agent = requested ?? DEFAULT_AGENT;

// そのエージェントが入っていない：この Mac の Apple のモデル（`fm`）で答える（Web は見ない）
if (!isInstalled(agent)) {
  const available = spawnSync("fm", ["available"], { encoding: "utf8" });
  if (available.error || available.status !== 0 || !/available/i.test(available.stdout) || /unavailable|not available/i.test(available.stdout)) {
    fail(`${agent} コマンドが、この Mac にありません（入れて、一度起動してログインしてください）。この Mac の Apple のモデル（fm）も、使えませんでした`, 127);
  }
  const instructions = "あなたは調べものの助手です。Web は見られません。自分の知識の範囲だけで答えます。知らないこと・自信のないことは、わからないと書きます。作り話をしません。";
  const run = spawnSync("fm", ["respond", "--no-stream", "-i", instructions, askKnowledge], { encoding: "utf8", maxBuffer: 4 * 1024 * 1024, timeout: 60_000 });
  const text = `${run.stdout ?? ""}`.trim();
  if (run.error || run.status !== 0 || !text) fail(`${agent} がなく、fm も答えませんでした（${(run.error?.message ?? run.stderr ?? "").toString().trim().slice(0, 200) || "答えが空"}）。${agent} を入れて、一度起動してログインしてください`);
  showWindow(`> **${agent} が入っていないので、Web は見ていません。** この Mac の Apple のモデル（\`fm\`）が、自分の知識の範囲で答えました。古い・不正確な内容を含むことがあります（発話は、この Mac の外へは出ていません）。\n> Web で調べるには、${agent} を入れてください（使えるエージェント：${IDS}）。\n\n${text}`);
  console.log(`ok: ${agent} がないので、fm（Apple のモデル。Web は見ない）の答えを、ウィンドウに表示しました（${text.length} 文字）`);
  process.exit(0);
}

const spec = AGENTS[agent];
// ファイルのない、空の作業フォルダで動かす（エージェントが、手元のファイルを読まない・書かない）
const work = mkdtempSync(join(tmpdir(), "ask-agent-"));
const outFile = join(work, ".answer.md");
try {
  const run = spawnSync(agent, spec.args(work, outFile), { cwd: work, encoding: "utf8", maxBuffer: 4 * 1024 * 1024, timeout: 115_000, stdio: ["ignore", "pipe", "pipe"] });
  if (run.error) fail(run.error.code === "ETIMEDOUT" ? `${agent} の答えが、時間内に返りませんでした（約 2 分）` : `${agent} を起動できません（${run.error.message}）`);
  let text = `${run.stdout ?? ""}`.trim();
  if (spec.answerFile) { try { text = readFileSync(outFile, "utf8").trim(); } catch { text = ""; } }
  const errors = `${run.stderr ?? ""}`.trim();
  if (run.status !== 0 || !text) {
    const detail = `${errors || text}`;
    if (/log ?in|sign ?in|auth|credential|unauthori[sz]ed|api key/i.test(detail)) fail(`${agent} にログインしていません（ターミナルで ${agent} を一度起動して、ログインしてください）`);
    fail(text ? `${agent} が失敗しました（終了コード ${run.status}）：${detail.slice(0, 300)}` : `${agent} の答えが空でした${errors ? `：${errors.slice(0, 300)}` : ""}`);
  }
  // 答え（Markdown）は、ここで、ウィンドウに出す（言語モデルに、長い文を、そのまま写させない：小さなモデルは、要約し直したり、削ったりする）
  const banner = spec.web ? "" : `> **${agent} は、Web を見られません。** モデルの知識の範囲で答えています。古い・不正確な内容を含むことがあります。\n\n`;
  showWindow(banner + text);
  console.log(`ok: ${agent} の答えを、ウィンドウに表示しました（${text.length} 文字）`);
} finally {
  rmSync(work, { recursive: true, force: true });
}
