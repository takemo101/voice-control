import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// 画面の取り込み：**選び始める前に、ディスプレイごとの静止画を撮る**（ScreenCaptureKit。`vc` 自身のウィンドウは、写さない）。選択の画面は、この静止画を見せる（動画・ポップアップが、選ぶ間に変わらない）。
/// 画面収録の許可が要る。
enum ScreenGrab {
    struct Frame {
        let displayID: CGDirectDisplayID
        /// ディスプレイ全体（ピクセル）。
        let image: CGImage
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// すべてのディスプレイの静止画。
    static func frames() async throws -> [Frame] {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw Failure(description: "画面を読み取れません（\(error.localizedDescription)）。\(ScreenCapture.permissionHint)") }
        let own = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == own }
        var frames: [Frame] = []
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
            configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
            configuration.showsCursor = false
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                frames.append(Frame(displayID: display.displayID, image: image))
            } catch { throw Failure(description: "画面を撮れません（\(error.localizedDescription)）。\(ScreenCapture.permissionHint)") }
        }
        guard !frames.isEmpty else { throw Failure(description: "ディスプレイが見つかりません") }
        return frames
    }

    /// 選べるウィンドウ（画面の上にある、通常のウィンドウ。手前から奥の順）。`vc` 自身・小さすぎるもの・透明なものは除く。
    static func windows() -> [(id: CGWindowID, bounds: CGRect, title: String)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != own,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width >= 40, bounds.height >= 40 else { return nil }
            let app = info[kCGWindowOwnerName as String] as? String ?? ""
            let name = info[kCGWindowName as String] as? String ?? ""
            return (id, bounds, name.isEmpty ? app : "\(app) — \(name)")
        }
    }
}
