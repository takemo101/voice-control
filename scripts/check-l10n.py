#!/usr/bin/env python3
"""表示言語の翻訳（言語ごとの表）を調べる・足す。

使い方：scripts/check-l10n.py [--uncovered] [--status] [--missing <言語>] [--new-language <言語> <型名>]
  既定：コードの `tr("…")` の鍵（補間は %@）が、**英語の表**（Sources/vc/L10n/en/）にあるか（英語は、すべての言語の引き先：抜けは、問題）。
        どの言語の表も：値の %@ の数が、鍵と合うか・鍵の重複（Swift の辞書は、重複で、実行時に落ちる）。使われない鍵（警告）。
        **英語以外の言語の、未訳（表にない・値が空）は、問題にしない**（その言語の表にない文は、英語で出る）。件数だけ、出す。
  --uncovered：設定ウィンドウ・ダイアログのファイルで、`tr(` に包まれていない日本語の文字列を探す（`// l10n-skip` を付けた行は、除く）。
  --status：言語ごとの、訳の数と割合。
  --missing <言語>：その言語の、未訳の鍵を、英語つきで、一覧にする（翻訳する人向け）。
  --new-language <言語> <型名>：新しい言語の表の、ひな形を作る（Sources/vc/L10n/<言語>/<型名>Tables.swift。値は、空：未訳）。足し方は docs/development.md の「言語を足す」。
終了コード：問題があれば 1。警告・未訳だけなら 0。
"""
import re, sys, glob, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JA = re.compile(r'[\u3040-\u30ff\u4e00-\u9fff]')

# 翻訳の対象のファイル（`--uncovered` の範囲）：設定ウィンドウとダイアログ
# `--uncovered` の範囲：`Sources/vc` の全部と、**`tr(` を 1 つでも使っている**ほかのターゲットのファイル（足すときに、ここへ書かなくてよい）。
# 日本語の文字列が、まったく包まれていない（`tr` を使っていない）ほかのターゲットのファイルは、調べない（モデルへの指示・照合の語が多い）。
SCOPE_ALWAYS = ['Sources/vc/**/*.swift']
SCOPE_ANY_TARGET = 'Sources/**/*.swift'
# 翻訳しないもの（開発用のコマンド・検証用の窓・表そのもの・モデルへの指示を持つファイル）。ここにないファイルで、日本語の文字列が `tr(` に包まれていなければ、報告する
EXCLUDE = [
    'Sources/VCCore/L10n.swift', 'Sources/vc/L10n/', 'Sources/vc/Commands/ChatCheck.swift', 'Sources/vc/Commands/EvalJudge.swift', 'Sources/vc/Commands/EvalPlan.swift', 'Sources/vc/Commands/EvalGate.swift', 'Sources/vc/Commands/Tidy.swift', 'Sources/vc/Commands/EvalRoute.swift',
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



L10N_DIR = os.path.join(ROOT, 'Sources/vc/L10n')


def languages():
    """表のフォルダ（Sources/vc/L10n/<言語>/）の言語。英語を先頭に。"""
    found = sorted(d for d in os.listdir(L10N_DIR) if os.path.isdir(os.path.join(L10N_DIR, d)))
    return (['en'] if 'en' in found else []) + [d for d in found if d != 'en']


def table(language):
    """その言語の表：(鍵 → 値, 重複, 動的な鍵)。値が空の項目は、未訳。"""
    entries, dups, dynamic = {}, [], set()
    for path in sorted(glob.glob(os.path.join(L10N_DIR, language, '*.swift'))):
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
            if m.group(3) and 'l10n-dynamic' in m.group(3):
                dynamic.add(k)
    return entries, dups, dynamic


def placeholders_ok(key, value):
    slots = key.count('%@')
    numbered = {int(x) for x in re.findall(r'%(\d+)\$@', value)}
    plain = value.count('%@')
    return (plain == slots and not numbered) or (plain == 0 and numbered == set(range(1, slots + 1)))


def translated(entries):
    return {k: v for k, v in entries.items() if v}


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
    files = set()
    for pattern in SCOPE_ALWAYS:
        files.update(glob.glob(os.path.join(ROOT, pattern), recursive=True))
    for path in glob.glob(os.path.join(ROOT, SCOPE_ANY_TARGET), recursive=True):
        if re.search(r'(?<![A-Za-z0-9_.])tr\(', open(path, encoding='utf-8').read()):
            files.add(path)
    if True:
        for path in sorted(files):
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


def swift_string(text):
    return '"' + text.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'


def new_language(code, type_name):
    """新しい言語の表のひな形。英語の表の鍵を、すべて、空の値で並べる（英語を、コメントに添える）。"""
    directory = os.path.join(L10N_DIR, code)
    if os.path.exists(directory):
        print(f'すでにあります：{os.path.relpath(directory, ROOT)}'); return 1
    english, _, _ = table('en')
    keys = list(english)
    chunk = 120
    parts = [keys[i:i + chunk] for i in range(0, len(keys), chunk)]
    os.makedirs(directory)
    lines = [
        'import Foundation', '',
        f'/// {type_name} の翻訳の表（日本語の文 → {type_name}）。**値が空の項目は、未訳**（その文は、英語で出る）。コメントの `en:` は、英語の訳（訳す人の手がかり）。',
        '/// 足し方：`docs/development.md` の「言語を足す」。抜けの確認：`scripts/check-l10n.py --status`・`--missing ' + code + '`。',
        f'enum {type_name}Tables {{',
        '    static let all: [String: String] = [' + ', '.join(f'part{i + 1}' for i in range(len(parts))) + '].reduce(into: [:]) { $0.merge($1) { _, new in new } }', '',
    ]
    for i, part in enumerate(parts):
        lines.append(f'    private static let part{i + 1}: [String: String] = [')
        for k in part:
            lines.append(f'        {swift_string(k)}: "",   // en: {english[k].splitlines()[0] if english[k] else ""}')
        lines += ['    ]', '']
    lines.append('}')
    open(os.path.join(directory, f'{type_name}Tables.swift'), 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
    print(f'作りました：Sources/vc/L10n/{code}/{type_name}Tables.swift（{len(keys)} 件）')
    print('次：AppLanguage に case を足す → LanguageProfile.swift に項目を書く → L10nTables.swift に表を登録する（コンパイルが、足りないところを教える）。docs/development.md の「言語を足す」を、見る。')
    return 0


def main():
    if '--new-language' in sys.argv:
        i = sys.argv.index('--new-language')
        if len(sys.argv) < i + 3:
            print('使い方：--new-language <言語の符号（例 fr）> <型名（例 French）>'); sys.exit(2)
        sys.exit(new_language(sys.argv[i + 1], sys.argv[i + 2]))
    used = used_keys()
    langs = languages()
    tables = {code: table(code) for code in langs}
    problems = 0
    english, _, english_dynamic = tables['en']
    # 英語：抜けは、問題（すべての言語の、引き先）
    for k, places in sorted(used.items()):
        if not english.get(k):
            problems += 1
            print(f'抜け：{places[0][0]}:{places[0][1]}  「{k[:70]}」')
    # どの言語も：置き換えの数・重複
    for code in langs:
        entries, dups, _ = tables[code]
        for k, v in entries.items():
            if v and not placeholders_ok(k, v):
                problems += 1
                print(f'置き換えの数が違う（{code}）：「{k[:60]}」 → 「{v[:60]}」')
        for path, n, k in dups:
            problems += 1
            print(f'重複：{path}:{n}  「{k[:60]}」')
    # 使われない鍵（警告）：英語の表で見る
    unused = [k for k in english if k not in used and k not in english_dynamic]
    for k in unused[:20]:
        print(f'警告：使われない鍵「{k[:60]}」')
    if len(unused) > 20:
        print(f'警告：使われない鍵が、ほかに {len(unused) - 20} 件')
    if '--status' in sys.argv:
        print('言語ごとの訳（コードの鍵に対する、訳の数）：')
        for code in langs:
            done = sum(1 for k in used if translated(tables[code][0]).get(k))
            print(f'  {code}: {done}/{len(used)}（{100 * done // max(len(used), 1)}%）')
    elif len(langs) > 1:
        for code in langs[1:]:
            missing = sum(1 for k in used if not translated(tables[code][0]).get(k))
            print(f'未訳（{code}）：{missing} 件（英語で出る）')
    if '--missing' in sys.argv:
        i = sys.argv.index('--missing')
        code = sys.argv[i + 1] if len(sys.argv) > i + 1 else ''
        if code not in tables:
            print(f'表がありません：{code}（あるのは {", ".join(langs)}）'); sys.exit(2)
        for k in used:
            if not translated(tables[code][0]).get(k):
                print(f'{k}\n    en: {english.get(k, "")}')
    entries_total = sum(len(tables[c][0]) for c in langs)
    print(f'tr の鍵 {len(used)} 件・表 {entries_total} 件（{", ".join(f"{c} {len(tables[c][0])}" for c in langs)}）・問題 {problems} 件')
    if '--uncovered' in sys.argv:
        found = uncovered()
        for path, n, s in found:
            print(f'包まれていない：{path}:{n}  {s}')
        print(f'包まれていない日本語の文字列：{len(found)} 件')
        problems += len(found)
    sys.exit(1 if problems else 0)


main()
