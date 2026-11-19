import Foundation
import VCCore

/// 更新を入れてよい場所か（**純粋**：書ける場所かの判定は、渡す）。ビルドしたままのアプリ・ディスクイメージの中・隔離（translocation）された起動を、置き換えない。
enum InstallPlan {
    enum Block: Equatable, CustomStringConvertible {
        case notAnApp
        case translocated
        case unusualLocation(String)
        case notWritable(String)

        var description: String {
            switch self {
            case .notAnApp: return tr("アプリとして動いていません（ビルドしたままの `vc` です）")
            case .translocated: return tr("隔離された場所から動いています。アプリを「アプリケーション」へ移して、開き直してください")
            case let .unusualLocation(path): return tr("「アプリケーション」フォルダのアプリではありません（\(path)）。更新は、「アプリケーション」へ入れたアプリにだけ、行います")
            case let .notWritable(directory): return tr("\(directory) に書けません。手動で、新しい版に入れ替えてください")
            }
        }
    }

    /// 入れ替えられないなら、理由。`isWritable`：そのフォルダに書けるか。
    static func block(appPath: String, home: String = NSHomeDirectory(), isWritable: (String) -> Bool) -> Block? {
        guard appPath.hasSuffix(".app") else { return .notAnApp }
        if appPath.contains("/AppTranslocation/") { return .translocated }
        let allowed = ["/Applications/", home + "/Applications/"]
        guard allowed.contains(where: { appPath.hasPrefix($0) }) else { return .unusualLocation(appPath) }
        let directory = (appPath as NSString).deletingLastPathComponent
        return isWritable(directory) ? nil : .notWritable(directory)
    }

    /// 置き換えの途中の名前（同じフォルダの中：同じボリュームなので、入れ替えが、名前の付け替えだけで済む）。
    static func stagedPath(for appPath: String) -> String { (appPath as NSString).deletingLastPathComponent + "/.VoiceControl-update.app" }
    static func backupPath(for appPath: String) -> String { (appPath as NSString).deletingLastPathComponent + "/.VoiceControl-old.app" }
}

/// アプリの入れ替え：このアプリが終わるのを待って、新しい版を置き、開き直す（別のシェルが、背景で行う）。失敗したら、元に戻す。
enum UpdateSwap {
    /// 引数：`$1` 待つプロセスの番号・`$2` 新しいアプリ・`$3` 置き換えるアプリ・`$4` 退避の場所・`$5` 開くコマンド。
    /// 終了コード：0 成功・1 待ちきれなかった（何も変えていない）・2 退避できなかった（何も変えていない）・3 置けなかった（元に戻した）。
    static let script = """
    pid="$1"; staged="$2"; target="$3"; backup="$4"; opener="$5"
    n=0
    while kill -0 "$pid" 2>/dev/null; do
      n=$((n+1)); [ "$n" -gt 100 ] && exit 1
      sleep 0.3
    done
    rm -rf "$backup"
    mv "$target" "$backup" || exit 2
    if mv "$staged" "$target"; then
      xattr -dr com.apple.quarantine "$target" 2>/dev/null
      "$opener" "$target"
      rm -rf "$backup"
      exit 0
    fi
    mv "$backup" "$target"
    "$opener" "$target"
    exit 3
    """

    /// 引数（`/bin/sh` へ）。**パスは、スクリプトに埋め込まず、引数で渡す**（引用の誤りで、別のものが消えない）。`background`：親が終わっても続くように、背景で動かす。
    static func arguments(pid: Int32, staged: String, target: String, backup: String, opener: String = "/usr/bin/open", background: Bool) -> [String] {
        let values = [String(pid), staged, target, backup, opener]
        if !background { return ["-c", script, "sh"] + values }
        // 外側のシェルが、内側を `&` で背景に回して、すぐ終わる（内側は、launchd の子になって、このアプリが終わっても続く）
        return ["-c", "/bin/sh -c \"$1\" sh \"$2\" \"$3\" \"$4\" \"$5\" \"$6\" >/dev/null 2>&1 &", "outer", script] + values
    }

    /// 背景で始める（アプリは、このあと終わる）。始められなければ、理由。
    static func launch(staged: String, target: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(pid: ProcessInfo.processInfo.processIdentifier, staged: staged, target: target, backup: InstallPlan.backupPath(for: target), background: true)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return tr("入れ替えを始められません（\(error.localizedDescription)）") }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? nil : tr("入れ替えを始められません（終了コード \(process.terminationStatus)）")
    }
}
