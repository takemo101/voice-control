import AppKit
import SwiftUI
import VCCore
import VCDecision
import VCSkill
import VCSpeech

// MARK: キー

struct KeysPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Callout(symbol: "hand.tap.fill", text: "キーを押している間だけ、話します。たとえば、Shift を押したまま「電卓を開いて」と言って、離すと、実行されます。キーの欄を押して、使いたいキーを押すと、決まります。")
        Card("押している間だけ話す", footer: "修飾キーだけのキー（⇧ ⌃ ⌥ ⌘）の長押しは、アクセシビリティの許可が要ります。右側のキーだけにすると、普段の入力での誤作動が減ります。") {
            ForEach(Array(KeyKind.allCases.enumerated()), id: \.element) { index, kind in
                if index > 0 { RowDivider() }
                KeyRow(model: model, kind: kind)
            }
        }
        Card("操作") {
            SwitchRow(model: model, title: "手放し（ダブルタップ）", detail: "キーを短く 2 回押すと、黙るまで録音します（押し続ける使い方も、そのまま使えます）", value: model.settings.handsFree ?? true) { $0.handsFree = $1 }
        }
    }
}

struct KeyRow: View {
    @ObservedObject var model: SettingsModel
    let kind: KeyKind

    var body: some View {
        let saved = model.settings[keyPath: kind.keyPath] ?? ""
        let isRecording = model.recording == kind
        let effective = saved.isEmpty ? (kind == .listen ? "shift" : "") : saved
        let label: String = {
            if case let .success(spec) = HotKeySpec.parse(effective) { return KeyRow.label(of: spec) }
            return effective.isEmpty ? "未設定" : "?"
        }()
        VStack(alignment: .leading, spacing: 6) {
            Row(kind.title, detail: kind.help) {
                HStack(spacing: 8) {
                    Button { isRecording ? model.stopRecording() : model.startRecording(kind) } label: {
                        Text(isRecording ? "キーを押してください…" : label)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(isRecording ? Brand.rec1 : (effective.isEmpty ? Color.secondary : Color.primary))
                            .padding(.horizontal, 12).frame(minWidth: 86, minHeight: 28)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isRecording ? Brand.rec2.opacity(0.14) : Color(nsColor: .windowBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isRecording ? Brand.rec1 : Color.primary.opacity(0.18), lineWidth: isRecording ? 1.5 : 1))
                            .shadow(color: .black.opacity(isRecording ? 0 : 0.16), radius: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help("押して、使いたいキーを押す（Esc で取りやめ）")
                    Menu {
                        ForEach(kind.presets, id: \.self) { preset in
                            Button(KeyRow.title(of: preset)) { model.setDraft(kind, preset); model.commitKey(kind) }
                        }
                        if kind.isOptional { Divider(); Button("使わない") { model.setDraft(kind, ""); model.commitKey(kind) } }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("候補から選ぶ")
                }
            }
            if isRecording {
                Label(model.recordingHint ?? "修飾キーだけなら、押して、離します。組み合わせなら、続けて押します。", systemImage: model.recordingHint == nil ? "keyboard" : "exclamationmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(model.recordingHint == nil ? Color.secondary : Brand.rec1)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            } else if let problem = model.keyProblems[kind] {
                Label(problem, systemImage: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
    }

    /// キーの表示：記号と、書き方（例：「⇧  shift」「右⌘  rcmd」「⌃⌥S  ctrl+opt+s」）。
    static func label(of spec: HotKeySpec) -> String {
        let symbols = String(spec.displayName.split(whereSeparator: { "(（".contains($0) })[0]).trimmingCharacters(in: .whitespaces)
        return "\(symbols)  \(spec.description)"
    }

    /// 候補メニューの表示。
    static func title(of preset: String) -> String {
        if case let .success(spec) = HotKeySpec.parse(preset) { return label(of: spec) }
        return preset
    }
}
