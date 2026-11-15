#!/bin/bash
# ビルドした dmg を、公開の前に検査する（ローカルでも、リリースのワークフローでも、同じもの）。
#
#   ./scripts/verify-dmg.sh dist/vc-<版>-macos-arm64.dmg [期待する版 X.Y.Z]
#
# 検査：dmg の整合、中身（アプリ・/Applications へのリンク・同梱のスキル）、アプリの版（指定したとき）、arm64 を含むこと、署名の整合（指定要件が bundle ID だけであること）、
#       OS 標準以外のライブラリに依存していないこと、アプリの中の `vc --version`・CLI（`vc show --help`）。ひとつでも失敗したら、終了コード 1。
# dmg を読み取り専用でマウントして調べ、終わったら必ずデタッチする。
# 注意：macOS 標準の bash 3.2 は、EXIT トラップがあると、致命的なエラーの終了コードを 0 にしてしまう。検査はサブシェルで走らせ、後始末は、その終了コードを保存してから行う（EXIT トラップは使わない）。
set -euo pipefail

DMG="${1:?usage: verify-dmg.sh <dmg> [version]}"
EXPECTED_VERSION="${2:-}"

fail() { echo "verify-dmg: FAIL: $*" >&2; exit 1; }
ok() { echo "verify-dmg: ok: $*"; }

[ -f "${DMG}" ] || fail "dmg が無い: ${DMG}"
MOUNT="$(mktemp -d)"

checks() {
    hdiutil verify "${DMG}" >/dev/null 2>&1 || fail "hdiutil verify が通らない"
    ok "dmg の整合（hdiutil verify）"

    hdiutil attach "${DMG}" -readonly -nobrowse -noverify -mountpoint "${MOUNT}" -quiet >/dev/null 2>&1 || fail "マウントできない"
    local app="${MOUNT}/VoiceControl.app"
    local exe="${app}/Contents/MacOS/vc"

    [ -d "${app}" ] || fail "VoiceControl.app が dmg に無い"
    [ -L "${MOUNT}/Applications" ] && [ "$(readlink "${MOUNT}/Applications")" = "/Applications" ] || fail "/Applications へのリンクが無い"
    ok "中身（VoiceControl.app、/Applications へのリンク）"

    [ -s "${app}/Contents/Resources/skills/voice-control-skill-author/SKILL.md" ] || fail "同梱のスキル（skills/voice-control-skill-author/SKILL.md）が無い"
    [ -s "${app}/Contents/Resources/LICENSE" ] && [ -s "${app}/Contents/Resources/THIRD_PARTY_NOTICES.md" ] || fail "LICENSE・THIRD_PARTY_NOTICES.md が無い"
    ok "同梱物（スキルを作るスキル・ライセンス）"

    local plist="${app}/Contents/Info.plist"
    local icon_name
    icon_name="$(plutil -extract CFBundleIconFile raw "${plist}" 2>/dev/null || true)"
    [ -n "${icon_name}" ] && [ -s "${app}/Contents/Resources/${icon_name}.icns" ] || fail "アイコン（CFBundleIconFile と Resources/*.icns）が無い"
    ok "アイコン（${icon_name}.icns）"
    for key in NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription NSAppleEventsUsageDescription; do
        plutil -extract "${key}" raw "${plist}" >/dev/null 2>&1 || fail "Info.plist に ${key} が無い"
    done
    [ "$(plutil -extract LSUIElement raw "${plist}")" = "true" ] || fail "LSUIElement が true でない（Dock に出てしまう）"
    ok "Info.plist（使用目的の説明・LSUIElement）"
    if [ -n "${EXPECTED_VERSION}" ]; then
        local short build
        short="$(plutil -extract CFBundleShortVersionString raw "${plist}")"
        build="$(plutil -extract CFBundleVersion raw "${plist}")"
        [ "${short}" = "${EXPECTED_VERSION}" ] || fail "アプリの版 ${short} が、期待する ${EXPECTED_VERSION} と違う"
        [ "${build}" = "${EXPECTED_VERSION}" ] || fail "CFBundleVersion ${build} が、期待する ${EXPECTED_VERSION} と違う"
        ok "アプリの版 ${short}"
    fi

    local archs
    archs="$(lipo -archs "${exe}")"
    case " ${archs} " in *" arm64 "*) ;; *) fail "arm64 を含まない（${archs}）" ;; esac
    ok "アーキテクチャ（${archs}）"

    # OS 標準（/usr/lib・/System）以外のライブラリに依存していないこと（持ち出した先で、動かなくなる）
    local external
    external="$(otool -L "${exe}" | tail -n +2 | awk '{print $1}' | grep -v -E '^(/usr/lib/|/System/Library/)' || true)"
    [ -z "${external}" ] || fail "OS 標準以外のライブラリに依存している: ${external}"
    ok "ライブラリ（OS 標準だけ）"

    codesign --verify --deep --strict "${app}" >/dev/null 2>&1 || fail "codesign --verify が通らない"
    local requirement bundle_id
    bundle_id="$(plutil -extract CFBundleIdentifier raw "${plist}")"
    requirement="$(codesign -d -r- "${app}" 2>&1 | grep '^designated' || true)"
    [ "${requirement}" = "designated => identifier \"${bundle_id}\"" ] || fail "指定要件が bundle ID だけでない（更新のたびに、許可が無効になる）: ${requirement}"
    ok "署名（codesign --verify・指定要件は bundle ID だけ）"

    # CLI：アプリの中の vc を、引数つきで動かす（引数なしは、メニューバーのアプリが起動するので、動かさない）
    if [ -n "${EXPECTED_VERSION}" ]; then
        local reported
        reported="$("${exe}" --version)"
        [ "${reported}" = "vc ${EXPECTED_VERSION}" ] || fail "--version が「${reported}」（期待：vc ${EXPECTED_VERSION}）"
        ok "--version（${reported}）"
    fi
    "${exe}" show --help >/dev/null 2>&1 || fail "CLI（vc show --help）が動かない"
    ok "CLI（vc show --help）"
}

set +e
( set -e; checks )
rc=$?
set -e

hdiutil detach "${MOUNT}" -quiet >/dev/null 2>&1 || hdiutil detach "${MOUNT}" -force -quiet >/dev/null 2>&1 || true
rmdir "${MOUNT}" 2>/dev/null || true

if [ "${rc}" -ne 0 ]; then
    echo "verify-dmg: FAILED (exit ${rc}): ${DMG}" >&2
    exit "${rc}"
fi
echo "verify-dmg: all checks passed: ${DMG}"
