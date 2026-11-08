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

    /// 範囲を選んで撮り、文字を読み取る（画像は、読み取ったら、すぐ消す）。取りやめは `nil`。文字がなければ、空の文字列。
    static func recognizeRegion() async -> Result<String?, ScreenCaptureFailure> {
        let file = ScreenshotStore.directory.appendingPathComponent("ocr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }   // try?: 後片付け
        switch await capture(to: file) {
        case .cancelled: return .success(nil)
        case let .failed(reason): return .failure(ScreenCaptureFailure(message: reason))
        case .captured:
            do { return .success(try ScreenText.recognize(file)) } catch { return .failure(ScreenCaptureFailure(message: "\(error)")) }
        }
    }
}

struct ScreenCaptureFailure: Error { let message: String }

/// 読み取った文字を、ウィンドウで見せる Markdown にする：**そのまま**（Markdown として解釈させない）。コードの囲みの中に入れ、囲みの記号は、中の `` ` `` より長くする。
enum TranscriptDocument {
    static func markdown(_ text: String) -> String {
        var longest = 0, run = 0
        for ch in text { if ch == "`" { run += 1; longest = max(longest, run) } else { run = 0 } }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\n\(text)\n\(fence)\n"
    }
}
