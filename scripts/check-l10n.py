#!/usr/bin/env python3
"""表示言語（英語）の翻訳の抜けを調べる。

使い方：scripts/check-l10n.py [--uncovered]
  既定：コードの `tr("…")` の鍵（補間は %@）が、英語の表（Sources/vc/L10n/English*.swift）にあるか。
        表の値の %@ の数が、鍵と合うか。表の鍵の重複（Swift の辞書は、重複で実行時に落ちる）。使われない鍵（警告）。
  --uncovered：設定ウィンドウ・ダイアログのファイルで、`tr(` に包まれていない日本語の文字列を探す（`// l10n-skip` を付けた行は除く）。
終了コード：問題（抜け・不一致・重複）があれば 1。警告（使われない鍵・包まれていない文字列）だけなら 0。
"""
import re, sys, glob, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JA = re.compile(r'[\u3040-\u30ff\u4e00-\u9fff]')

# 翻訳の対象のファイル（`--uncovered` の範囲）：設定ウィンドウとダイアログ
SCOPE = [
    'Sources/vc/App/Settings/*.swift', 'Sources/vc/App/AppRuntime.swift', 'Sources/vc/App/AppActions.swift',
    'Sources/vc/App/DiagnosticsWindow.swift', 'Sources/vc/Update/*.swift', 'Sources/vc/Adapters/*.swift', 'Sources/vc/CommandChoices.swift',
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
            entries[k] = v
    return entries, dups


def uncovered():
    found = []
    for pattern in SCOPE:
        for path in sorted(glob.glob(os.path.join(ROOT, pattern))):
            text = open(path, encoding='utf-8').read()
            lines = text.split('\n')
            for n, line in enumerate(lines, 1):
                code = line
                if code.strip().startswith('//') or 'l10n-skip' in line:
                    continue
                # 文字列の外の `//` 以降は、コメント
                i, in_str, out = 0, False, ''
                while i < len(code):
                    c = code[i]
                    if in_str:
                        out += c
                        if c == '\\': out += code[i + 1:i + 2]; i += 2; continue
                        if c == '"': in_str = False
                    else:
                        if code.startswith('//', i): break
                        if c == '"': in_str = True
                        out += c
                    i += 1
                for m in re.finditer(r'"((?:[^"\\]|\\.)*)"', out):
                    if not JA.search(m.group(1)):
                        continue
                    before = out[:m.start()].rstrip()
                    if before.endswith('tr(') or before.endswith('tr(verbatim:'):
                        continue
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
    sys.exit(1 if problems else 0)


main()
