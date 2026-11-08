import CoreGraphics
import Foundation
import VCCore
import VCSkill

/// 範囲を選んで、スクリーンショットを撮る（`ScreenSelector`：静止画を暗くして、ドラッグ・ウィンドウのクリック・全画面で選ぶ）。
/// 撮った画像は、この Mac の中だけに置く（`ScreenshotStore`）。**画面収録の許可**が要る（ターミナルなど、`vc` を動かしているアプリに）。
/// イベントのループ（`NSApplication.run()`）が回っているときに呼ぶ（`vc listen --hotkey`。単独のコマンドは、`ScreenSelector.runStandalone`）。
@MainActor enum ScreenCapture {
    enum Outcome {
        case captured(width: Int, height: Int)
        case cancelled
        case failed(String)
    }

    nonisolated static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

    nonisolated static let permissionHint = "システム設定 > プライバシーとセキュリティ > 画面収録 で、vc を動かしているターミナルを許可してください（許可したら、ターミナルを開き直す）"

    /// 範囲を選んで撮り、`destination`（PNG）へ書く。
    static func capture(to destination: URL) async -> Outcome {
        guard isAllowed else { return .failed("画面収録の許可がありません。\(permissionHint)") }
        switch await ScreenSelector.select() {
        case .cancelled: return .cancelled
        case let .failed(reason): return .failed(reason)
        case let .captured(capture):
            do {
                try ScreenshotStore.prepare(directory: destination.deletingLastPathComponent())
                try ImageOps.write(capture.image, to: destination, format: .png)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                return .captured(width: capture.image.width, height: capture.image.height)
            } catch {
                try? FileManager.default.removeItem(at: destination)   // try?: 書きかけは、残さない（後片付け）
                return .failed("撮った画像を保存できません（\(error)）")
            }
        }
    }

    /// 範囲を選んで撮り、いまのスクリーンショットにする（声で指示する相手）。
    static func captureForVoice() async -> Outcome {
        let file = ScreenshotStore.directory.appendingPathComponent("capture-\(UUID().uuidString).png")
        let outcome = await capture(to: file)
        if case .captured = outcome {
            do { try ScreenshotStore.replace(with: file) } catch {
                try? FileManager.default.removeItem(at: file)   // try?: 後片付け
                return .failed("スクリーンショットを置けません（\(error.localizedDescription)）")
            }
        }
        return outcome
    }
}

