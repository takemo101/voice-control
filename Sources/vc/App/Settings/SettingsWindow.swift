import AppKit
import SwiftUI
import VCCore
import VCDecision
import VCSkill
import VCSpeech

/// 設定ウィンドウ（meeting-analyzer の設定ウィンドウと同じ作り：左にページ・右に設定）。閉じても、アプリは終了しない。
@MainActor final class SettingsWindow {
    static let shared = SettingsWindow()
    private let model = SettingsModel()
    private var window: NSWindow?

    func show(page: SettingsPage? = nil) {
        model.reload()
        if let page { model.page = page }
        if window == nil { window = Self.makeWindow(model: model) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// ウィンドウの作り（アプリと、`vc settings-preview` が、同じものを使う：描いた絵が、実際の見た目になる）。内容の大きさは、タイトルバーの下まで、ぴったり。
    static func makeWindow(model: SettingsModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: settingsWidth, height: settingsHeight), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.title = tr("voice-control の設定")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

let settingsWidth: CGFloat = 820
let settingsHeight: CGFloat = 640

// MARK: 全体

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let _ = model.revision
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: 214)
            Divider()
            VStack(spacing: 0) {
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.red)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.red.opacity(0.1))
                }
                switch model.applyState {
                case .idle: EmptyView()
                case .applying:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(tr("設定を反映しています…")).font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9).background(Brand.rec2.opacity(0.14))
                case .applied:
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.ok)
                        Text(tr("反映しました")).font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9).background(Brand.ok.opacity(0.14))
                case let .failed(reason):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.rec1)
                            Text(tr("設定を反映できませんでした")).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Button(tr("もう一度")) { model.retryApply() }.controlSize(.small)
                            Button(tr("再起動")) { AppActions.relaunch() }.controlSize(.small)
                        }
                        Text(reason).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9).background(Brand.rec1.opacity(0.12))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        PageHeader(page: model.page)
                        switch model.page {
                        case .keys: KeysPage(model: model)
                        case .voice: VoicePage(model: model)
                        case .chat: ChatPage(model: model)
                        case .models: ModelsPage(model: model)
                        case .skills: SkillsPage(model: model)
                        case .general: GeneralPage(model: model)
                        }
                    }
                    .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: settingsWidth, maxWidth: .infinity, minHeight: settingsHeight, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

private struct Sidebar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let icon = NSApp.applicationIconImage { Image(nsImage: icon).resizable().frame(width: 38, height: 38) }
                VStack(alignment: .leading, spacing: 1) {
                    Text("voice-control").font(.system(size: 14, weight: .semibold))
                    Text(tr("バージョン \(AppInfo.version)")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.top, 38).padding(.bottom, 18)
            VStack(spacing: 2) {
                ForEach(SettingsPage.allCases) { page in
                    Button { model.page = page } label: {
                        HStack(spacing: 10) {
                            SettingsBadge(symbol: page.symbol, colors: page.colors)
                            Text(page.title).font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(model.page == page ? Color.primary.opacity(0.10) : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            Spacer()
            Text(tr("音声・画面は、") + "\n" + tr("この Mac の外へ出しません")).font(.system(size: 10)).foregroundStyle(.tertiary).padding(16)
        }
        .frame(maxHeight: .infinity)
        .background(VisualEffect(material: .sidebar))
    }
}

struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}
