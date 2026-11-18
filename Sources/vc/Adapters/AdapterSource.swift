import Foundation
import VCSkill

/// 同梱の固定ファイル（`adapters/<名前>/package.json`・`package-lock.json`）の場所。アプリ（`VoiceControl.app/Contents/Resources/adapters`）・開発（実行ファイルの上の、リポジトリの `adapters`）・環境変数 `VC_ADAPTERS_SOURCE`（テスト・検証用）の順に探す。
enum AdapterSource {
    static func directory(for adapter: ACPAdapter) -> URL? {
        var candidates: [URL] = []
        if let custom = ProcessInfo.processInfo.environment["VC_ADAPTERS_SOURCE"], !custom.isEmpty { candidates.append(URL(fileURLWithPath: custom)) }
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("adapters")) }
        // 開発：実行ファイル（`.build/release/vc`）から上へ、`adapters` のあるフォルダ（リポジトリ）を探す
        if let executable = AppLaunch.executablePath {
            var folder = URL(fileURLWithPath: executable).deletingLastPathComponent()
            for _ in 0..<6 { candidates.append(folder.appendingPathComponent("adapters")); folder.deleteLastPathComponent() }
        }
        return candidates.map { $0.appendingPathComponent(adapter.directoryName) }.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("package-lock.json").path) }
    }
}
