import AppKit
import SwiftUI
import VCCore

/// 診断ウィンドウ：`vc doctor` と同じ確認（`DoctorCommand.collect`）を、見やすく出す。使えないものには、直す手順を添える。
@MainActor final class DiagnosticsModel: ObservableObject {
    @Published private(set) var checks: [DoctorCheck] = []
    @Published private(set) var running = false
    @Published private(set) var copied = false

    var failures: Int { checks.filter { $0.state == .fail }.count }
    var warnings: Int { checks.filter { $0.state == .warn }.count }

    func run() {
        guard !running else { return }
        running = true
        Task {
            var arguments = Arguments([])
            let context = CommandContext(options: CommonOptions(consuming: &arguments))
            let result = await DoctorCommand.collect(context, includeClipboard: false)
            checks = result
            running = false
        }
    }

    /// 結果を、文字で（コピー用。発話・画面の内容は含まない：項目名・状態・直し方だけ）。
    func text() -> String {
        var lines = ["voice-control \(AppInfo.version)・macOS \(DoctorCommand.osVersion)"]
        for check in checks {
            let mark = check.state == .ok ? "OK" : (check.state == .warn ? "注意" : "NG")
            lines.append("[\(mark)] \(check.name)：\(check.detail)")
            if let fix = check.fix { lines.append("      → \(fix)") }
        }
        return lines.joined(separator: "\n")
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(), forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
    }
}

@MainActor final class DiagnosticsWindow {
    static let shared = DiagnosticsWindow()
    private let model = DiagnosticsModel()
    private var window: NSWindow?

    func show() {
        if window == nil { window = Self.makeWindow(model: model) }
        model.run()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func makeWindow(model: DiagnosticsModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: DiagnosticsView(model: model))
        window.title = "診断"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 420)
        window.center()
        return window
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: DiagnosticsModel

    private var tone: (symbol: String, colors: [Color], title: String, subtitle: String) {
        if model.running && model.checks.isEmpty { return ("ellipsis", [Color(white: 0.6), Color(white: 0.4)], "確かめています…", "少し、お待ちください") }
        if model.failures > 0 { return ("xmark", [Brand.rec1, Color(red: 0.8, green: 0.2, blue: 0.2)], "使えないものがあります", "\(model.failures) 件。下の手順で、直してください") }
        if model.warnings > 0 { return ("exclamationmark", [Brand.warn, Brand.rec2], "ほぼ、使えます", "\(model.warnings) 件は、任意の機能の設定です") }
        return ("checkmark", [Brand.ok, Color(red: 0.15, green: 0.65, blue: 0.45)], "すべて使えます", "必要なものは、そろっています")
    }

    var body: some View {
        let tone = tone
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: tone.symbol).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(LinearGradient(colors: tone.colors, startPoint: .top, endPoint: .bottom)))
                    .shadow(color: tone.colors.last!.opacity(0.4), radius: 6, y: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tone.title).font(.system(size: 20, weight: .bold))
                    Text(tone.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.running { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 24).padding(.top, 38).padding(.bottom, 16)
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.checks) { check in CheckCard(check: check) }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text("voice-control \(AppInfo.version)・macOS \(DoctorCommand.osVersion)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { model.copy() } label: { Label(model.copied ? "コピーしました" : "結果をコピー", systemImage: model.copied ? "checkmark" : "doc.on.doc") }.controlSize(.small)
                Button { model.run() } label: { Label("もう一度、確かめる", systemImage: "arrow.clockwise") }.controlSize(.small).disabled(model.running)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 560, minHeight: 420)
        .ignoresSafeArea()
    }
}

private struct CheckCard: View {
    let check: DoctorCheck

    private var style: (symbol: String, color: Color) {
        switch check.state {
        case .ok: return ("checkmark.circle.fill", Brand.ok)
        case .warn: return ("exclamationmark.circle.fill", Brand.warn)
        case .fail: return ("xmark.circle.fill", Brand.rec1)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.symbol).font(.system(size: 18)).foregroundStyle(style.color).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(check.name).font(.system(size: 13, weight: .semibold))
                Text(check.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let fix = check.fix {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "lightbulb.fill").font(.system(size: 10)).foregroundStyle(style.color).padding(.top, 2)
                        Text(fix).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(style.color.opacity(0.12)))
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}
