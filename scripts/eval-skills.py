#!/usr/bin/env python3
"""スキルごとに、依頼から、正しいコマンドが出るかを測る（--dry-run：実行しない）。

使い方：scripts/eval-skills.py [--engine apple|ollama:<モデル>] [--rounds N] [--skill <名前>] [--corpus corpus/skills.tsv]
  - 一時の VC_HOME に、このリポジトリの .voice-control/skills をコピーして、スキルを指定して（--skill）、1 依頼ずつ、vc run --dry-run --no-plan を動かす。
  - 利用者の設定・スキル・クリップボードには、触らない。実行はしない（--dry-run）：コマンドの中身が、正しいかだけを見る。
  - 照合は corpus/skills.tsv の説明を参照。
"""
import argparse, os, re, shutil, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ap = argparse.ArgumentParser()
ap.add_argument("--engine", default="apple")
ap.add_argument("--rounds", type=int, default=3)
ap.add_argument("--skill")
ap.add_argument("--corpus", default=os.path.join(ROOT, "corpus", "skills.tsv"))
ap.add_argument("--jobs", type=int, default=2)
args = ap.parse_args()

vc = os.path.join(ROOT, ".build", "release", "vc")
if not os.access(vc, os.X_OK):
    sys.exit(f"vc が見つかりません（just build）: {vc}")
home = tempfile.mkdtemp(prefix="vc-eval-skills-")
shutil.copytree(os.path.join(ROOT, ".voice-control", "skills"), os.path.join(home, "skills"))
env = {**os.environ, "VC_HOME": home, "NO_COLOR": "1"}

rows = []
for line in open(args.corpus, encoding="utf-8"):
    if line.startswith("#") or not line.strip():
        continue
    skill, mode, expected, utterance = line.rstrip("\n").split("\t", 3)
    if args.skill and skill != args.skill:
        continue
    rows.append((skill, mode, expected, utterance))

def commands(output):
    found, denied = [], []
    for raw in output.splitlines():
        text = raw.strip()
        if text.startswith("$ "):
            found.append(re.sub(r"\S*/skills/[a-z-]+/", "", text[2:]))
        elif text.startswith("✗ 拒否:"):
            denied.append(re.sub(r"\S*/skills/[a-z-]+/", "", text[len("✗ 拒否:"):].split("  —")[0].strip()))
    return found, denied

def judge(mode, expected, got):
    if mode == "exact":
        return got == [expected]
    if mode == "first":
        return bool(got) and got[0].startswith(expected)
    if mode == "has":
        return any(re.search(expected, c) for c in got)
    raise SystemExit(f"知らない照合: {mode}")

def run(job):
    skill, mode, expected, utterance, _ = job
    out = subprocess.run([vc, "run", utterance, "--skill", skill, "--engine", args.engine, "--dry-run", "--no-plan", "--yes"],
                         env=env, capture_output=True, text=True).stdout
    got, denied = commands(out)
    return skill, utterance, expected, got, denied, judge(mode, expected, got)

jobs = [(s, m, e, u, r) for (s, m, e, u) in rows for r in range(args.rounds)]
try:
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(run, jobs))
finally:
    shutil.rmtree(home, ignore_errors=True)

print(f"エンジン {args.engine}・{args.rounds} 回ずつ・--dry-run")
skills = []
for r in results:
    if r[0] not in skills:
        skills.append(r[0])
total_ok = total = 0
for skill in skills:
    mine = [r for r in results if r[0] == skill]
    ok = sum(1 for r in mine if r[5])
    total_ok += ok; total += len(mine)
    print(f"\n{skill}: {ok}/{len(mine)}（{round(100 * ok / len(mine))}%）")
    seen = set()
    for _, utterance, expected, got, denied, good in mine:
        key = (utterance, tuple(got))
        if good or key in seen:
            continue
        seen.add(key)
        extra = f"　拒否されたコマンド: {' ; '.join(denied)}" if denied else ""
        print(f"  ✗ {utterance}\n      期待 {expected}\n      実際 {' ; '.join(got) if got else '(コマンドなし)'}{extra}")
print(f"\n全体: {total_ok}/{total}（{round(100 * total_ok / total)}%）")
