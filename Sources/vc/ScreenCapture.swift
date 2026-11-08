import CoreGraphics
import Foundation
import VCCore
import VCSkill

/// 範囲を選んで、スクリーンショットを撮る（macOS 標準の `screencapture -i`：画面を暗くして、ドラッグで範囲を選ぶ。Esc で取りやめ）。
/// 撮った画像は、この Mac の中だけに置く（`ScreenshotStore`）。**画面収録の許可**が要る（ターミナルなど、`vc` を動かしているアプリに）。
enum ScreenCapture {
    enum Outcome {
        case captured(width: Int, height: Int)
        case cancelled
        case failed(String)
    }

    /// 範囲の選択を待つ時間の上限（秒）。
    static let selectionTimeout: TimeInterval = 180

    static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

    static let permissionHint = "システム設定 > プライバシーとセキュリティ > 画面収録 で、vc を動かしているターミナルを許可してください（許可したら、ターミナルを開き直す）"

    /// 範囲を選んで撮り、`destination`（PNG）へ書く。呼ぶと、選び終わるまで戻らない（メインのスレッドでは呼ばない）。
    static func captureRegion(to destination: URL) -> Outcome {
        guard isAllowed else { return .failed("画面収録の許可がありません。\(permissionHint)") }
        do { try ScreenshotStore.prepare(directory: destination.deletingLastPathComponent()) } catch { return .failed("保存先を用意できません（\(error.localizedDescription)）") }
        let result = ProcessRunner.run(executable: "screencapture", arguments: ["-i", "-x", "-t", "png", destination.path], mergeStderr: true, timeout: selectionTimeout)
        if result.timedOut { return .failed("範囲が選ばれないまま、\(Int(selectionTimeout)) 秒たちました") }
        // Esc で取りやめると、終了コード 0 で、ファイルができない
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return result.exitCode == 0 ? .cancelled : .failed("screencapture が失敗しました（\(result.exitCode)：\(String(result.text.prefix(200)))）")
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let size = try ImageOps.size(of: destination)
            return .captured(width: size.width, height: size.height)
        } catch {
            try? FileManager.default.removeItem(at: destination)   // try?: 読めない画像は、残さない（後片付け）
            return .failed("撮った画像を読めません（\(error)）")
        }
    }

    /// 範囲を選んで撮り、いまのスクリーンショットにする（声で指示する相手）。
    static func captureForVoice() -> Outcome {
        let file = ScreenshotStore.directory.appendingPathComponent("capture-\(UUID().uuidString).png")
        let outcome = captureRegion(to: file)
        if case .captured = outcome {
            do { try ScreenshotStore.replace(with: file) } catch {
                try? FileManager.default.removeItem(at: file)   // try?: 後片付け
                return .failed("スクリーンショットを置けません（\(error.localizedDescription)）")
            }
        }
        return outcome
    }

    /// 範囲を選んで撮り、文字を読み取る（画像は、読み取ったら、すぐ消す）。文字がなければ、空の文字列。
    static func recognizeRegion() -> Result<String?, ScreenCaptureFailure> {
        let file = ScreenshotStore.directory.appendingPathComponent("ocr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }   // try?: 後片付け
        switch captureRegion(to: file) {
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
