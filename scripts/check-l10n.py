#!/usr/bin/env python3
"""表示言語（英語）の翻訳の抜けを調べる。

使い方：scripts/check-l10n.py [--uncovered]
  既定：コードの `tr("…")` の鍵（補間は %@）が、英語の表（Sources/vc/L10n/English*.swift）にあるか。
        表の値の %@ の数が、鍵と合うか。表の鍵の重複（Swift の辞書は、重複で実行時に落ちる）。使われない鍵（警告）。
  --uncovered：設定ウィンドウ・ダイアログのファイルで、`tr(` に包まれていない日本語の文字列を探す（`// l10n-skip` を付けた行は除く）。
終了コード：問題（抜け・不一致・重複・`--uncovered` で見つけた包まれていない文字列）があれば 1。警告（使われない鍵）だけなら 0。
"""
import re, sys, glob, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JA = re.compile(r'[\u3040-\u30ff\u4e00-\u9fff]')

# 翻訳の対象のファイル（`--uncovered` の範囲）：設定ウィンドウとダイアログ
SCOPE = [
    'Sources/vc/**/*.swift',
    # 画面に出る文字を持つ、ほかのターゲットのファイル（足したら、ここへ）
    'Sources/VCSkill/AppleIntelligence.swift', 'Sources/VCSkill/Engine.swift', 'Sources/VCSkill/FrontMatter.swift', 'Sources/VCSkill/CommandPolicy.swift', 'Sources/VCSkill/SkillStore.swift',
    'Sources/VCSkill/Chat/ChatActivity.swift', 'Sources/VCSkill/Chat/ChatAgent.swift', 'Sources/VCSkill/Chat/ChatBackend.swift', 'Sources/VCSkill/Chat/ToolUseGuard.swift', 'Sources/VCSkill/Chat/AgentStream.swift', 'Sources/VCSkill/Chat/ACP/ACPPermissionText.swift', 'Sources/VCSkill/Chat/ACP/ACPCommandSummary.swift', 'Sources/VCSkill/Chat/ACP/ACPChatBackend.swift', 'Sources/VCSkill/Chat/ACP/ACPConnection.swift',
    'Sources/VCSkill/DefaultSkill.swift', 'Sources/VCSkill/SkillRunner.swift', 'Sources/VCSkill/Skill.swift', 'Sources/VCSkill/ImageOps.swift', 'Sources/VCSkill/VisionModel.swift', 'Sources/VCSkill/ImageSource.swift', 'Sources/VCSkill/BackgroundRemoval.swift', 'Sources/VCSkill/FileSearch.swift', 'Sources/VCSkill/RemoteSkills.swift', 'Sources/VCSkill/CommandSession.swift', 'Sources/VCSkill/ImageEditing.swift', 'Sources/VCSkill/ToolLoopAgent.swift',
    'Sources/VCSpeech/FileTranscriber.swift', 'Sources/VCSpeech/HotKeySpec.swift', 'Sources/VCSpeech/KeyStroke.swift', 'Sources/VCSpeech/LocalTranscriber.swift', 'Sources/VCSpeech/ClipboardPaste.swift', 'Sources/VCSpeech/HandsFreeTrigger.swift',
    'Sources/VCSpeech/MicRecorder.swift', 'Sources/VCSpeech/SpeechVoice.swift', 'Sources/VCSpeech/FillerWords.swift', 'Sources/VCSpeech/SpeechEngine.swift', 'Sources/VCCore/ModelStore.swift',
]
# 翻訳しないもの（開発用のコマンド・検証用の窓・表そのもの・モデルへの指示を持つファイル）。ここにないファイルで、日本語の文字列が `tr(` に包まれていなければ、報告する
EXCLUDE = [
    'Sources/vc/L10n/', 'Sources/vc/Commands/ChatCheck.swift', 'Sources/vc/Commands/EvalJudge.swift', 'Sources/vc/Commands/EvalPlan.swift', 'Sources/vc/Commands/EvalGate.swift',
    'Sources/vc/Commands/HudPreview.swift', 'Sources/vc/Commands/ChatPreview.swift', 'Sources/vc/Commands/SettingsPreview.swift', 'Sources/Fixture/',
]

ESC = {'n': '\n', 't': '\t', '"': '"', '\\': '\\', "'": "'", '0': '\0'}


def unescape(raw):
    out, i = '', 0
    while i < len(raw):
        c = raw[i]
        if c == '\\' and i + 1 < len(raw):
            out += ESC.get(raw[i + 1], raw[i + 1]); i += 2
        else:
            out += c; i += 1
    return out


def read_literal(text, i):
    """text[i] が開きの `"` のとき、(鍵, 次の位置)。補間は %@。複数行の文字列は対象外（None）。"""
    assert text[i] == '"'
    if text.startswith('"""', i):
        return None
    i += 1
    key, count = '', 0
    while i < len(text):
        c = text[i]
        if c == '\n':
            return None
        if c == '\\':
            if text[i + 1] == '(':
                depth, j = 1, i + 2
                while j < len(text) and depth:
                    if text[j] == '"':   # 補間の中の文字列
                        j += 1
                        while j < len(text) and text[j] != '"':
                            j += 2 if text[j] == '\\' else 1
                    elif text[j] == '(':
                        depth += 1
                    elif text[j] == ')':
                        depth -= 1
                    j += 1
                key += '%@'; count += 1; i = j; continue
            key += unescape(text[i:i + 2]); i += 2; continue
        if c == '"':
            return key, i + 1
        key += c; i += 1
    return None


def used_keys():
    keys = {}
    for path in glob.glob(os.path.join(ROOT, 'Sources/**/*.swift'), recursive=True):
        if '/L10n/' in path or path.endswith('/L10n.swift'):
            continue
        text = open(path, encoding='utf-8').read()
        for m in re.finditer(r'(?<![A-Za-z0-9_.])tr\(\s*"', text):
            start = m.end() - 1
            got = read_literal(text, start)
            if got is None:
                line = text.count('\n', 0, start) + 1
                print(f'警告：tr の文字列を読めません（複数行・不正）: {os.path.relpath(path, ROOT)}:{line}')
                continue
            key = got[0]
            keys.setdefault(key, []).append((os.path.relpath(path, ROOT), text.count('\n', 0, start) + 1))
    return keys


LINE = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"\s*,?\s*(//.*)?$')


def table():
    entries, dups = {}, []
    for path in sorted(glob.glob(os.path.join(ROOT, 'Sources/vc/L10n/English*.swift'))):
        if path.endswith('EnglishTables.swift'):
            continue
        seen = set()
        for n, line in enumerate(open(path, encoding='utf-8').read().split('\n'), 1):
            m = LINE.match(line)
            if not m:
                if line.strip().startswith('"') and ':' in line:
                    print(f'警告：表の行を読めません: {os.path.relpath(path, ROOT)}:{n}')
                continue
            k, v = unescape(m.group(1)), unescape(m.group(2))
            if k in seen:
                dups.append((os.path.relpath(path, ROOT), n, k))
            seen.add(k)
            if k in entries and entries[k] != v:
                dups.append((os.path.relpath(path, ROOT), n, k + '（別のファイルで、違う訳）'))
            entries[k] = v
    return entries, dups


def blank_tr_literals(text):
    """`tr("…")` の文字列を、空白に置き換える（行の数は、そのまま）。補間の中の文字列も、含めて。"""
    out = list(text)
    for m in re.finditer(r'(?<![A-Za-z0-9_.])tr\(\s*"', text):
        start = m.end() - 1
        got = read_literal(text, start)
        if got is None:
            continue
        for i in range(start, got[1]):
            if out[i] != '\n':
                out[i] = ' '
    return ''.join(out)


def uncovered():
    found = []
    for pattern in SCOPE:
        for path in sorted(glob.glob(os.path.join(ROOT, pattern), recursive=True)):
            if any(os.path.relpath(path, ROOT).startswith(x) for x in EXCLUDE):
                continue
            original = open(path, encoding='utf-8').read().split('\n')
            lines = blank_tr_literals('\n'.join(original)).split('\n')
            for n, line in enumerate(lines, 1):
                if original[n - 1].strip().startswith('//') or 'l10n-skip' in original[n - 1]:
                    continue
                # 文字列の外の `//` 以降は、コメント
                i, in_str, out = 0, False, ''
                while i < len(line):
                    c = line[i]
                    if in_str:
                        out += c
                        if c == '\\': out += line[i + 1:i + 2]; i += 2; continue
                        if c == '"': in_str = False
                    else:
                        if line.startswith('//', i): break
                        if c == '"': in_str = True
                        out += c
                    i += 1
                for m in re.finditer(r'"((?:[^"\\]|\\.)*)"', out):
                    if JA.search(m.group(1)):
                        found.append((os.path.relpath(path, ROOT), n, m.group(0)[:60]))
    return found


def main():
    used = used_keys()
    entries, dups = table()
    problems = 0
    for k, places in sorted(used.items()):
        if k not in entries:
            problems += 1
            print(f'抜け：{places[0][0]}:{places[0][1]}  「{k[:70]}」')
        else:
            slots = k.count('%@')
            value = entries[k]
            numbered = {int(x) for x in re.findall(r'%(\d+)\$@', value)}
            plain = value.count('%@')
            if not (plain == slots and not numbered) and not (plain == 0 and numbered == set(range(1, slots + 1))):
                problems += 1
                print(f'置き換えの数が違う：「{k[:60]}」 → 「{value[:60]}」')
    for path, n, k in dups:
        problems += 1
        print(f'重複：{path}:{n}  「{k[:60]}」')
    unused = [k for k in entries if k not in used]
    for k in unused[:20]:
        print(f'警告：使われない鍵「{k[:60]}」')
    if len(unused) > 20:
        print(f'警告：使われない鍵が、ほかに {len(unused) - 20} 件')
    print(f'tr の鍵 {len(used)} 件・表 {len(entries)} 件・問題 {problems} 件')
    if '--uncovered' in sys.argv:
        found = uncovered()
        for path, n, s in found:
            print(f'包まれていない：{path}:{n}  {s}')
        print(f'包まれていない日本語の文字列：{len(found)} 件')
        problems += len(found)
    sys.exit(1 if problems else 0)


main()
