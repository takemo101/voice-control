import AppKit
import SwiftUI
import VCCore
import VCDecision
import VCSkill
import VCSpeech

// MARK: 見た目の部品

/// 画面の上のパネル（HUD）と、アイコンに合わせた色。
enum Brand {
    static let rec1 = Color(red: 1.0, green: 0.30, blue: 0.28)
    static let rec2 = Color(red: 1.0, green: 0.62, blue: 0.20)
    static let think1 = Color(red: 0.40, green: 0.82, blue: 1.0)
    static let think2 = Color(red: 0.72, green: 0.42, blue: 0.98)
    static let ok = Color(red: 0.30, green: 0.85, blue: 0.52)
    static let warn = Color(red: 1.0, green: 0.80, blue: 0.25)
    static let accent = LinearGradient(colors: [rec2, rec1], startPoint: .top, endPoint: .bottom)
}

extension SettingsPage {
    /// サイドバーの角丸の色（上から下へ、少し濃くなる）。
    var colors: [Color] {
        switch self {
        case .keys: return [Brand.rec2, Brand.rec1]
        case .voice: return [Brand.think1, Color(red: 0.25, green: 0.55, blue: 0.95)]
        case .dictation: return [Color(red: 0.98, green: 0.72, blue: 0.30), Color(red: 0.90, green: 0.50, blue: 0.20)]
        case .transcribe: return [Color(red: 0.35, green: 0.85, blue: 0.80), Color(red: 0.10, green: 0.60, blue: 0.70)]
        case .history: return [Color(red: 0.60, green: 0.62, blue: 0.95), Color(red: 0.38, green: 0.40, blue: 0.80)]
        case .chat: return [Color(red: 0.40, green: 0.82, blue: 1.0), Color(red: 0.58, green: 0.40, blue: 0.96)]
        case .models: return [Brand.think2, Color(red: 0.45, green: 0.30, blue: 0.90)]
        case .skills: return [Brand.ok, Color(red: 0.15, green: 0.65, blue: 0.45)]
        case .general: return [Color(white: 0.62), Color(white: 0.42)]
        }
    }

    var subtitle: String {
        switch self {
        case .keys: return tr("押している間だけ話すキー・ショートカット")
        case .voice: return tr("認識の言語・録音・読み上げ")
        case .dictation: return tr("自分の声を、文字にして入力：送るキー・整え方・整理")
        case .transcribe: return tr("Mac から出ている音を、文字にする")
        case .history: return tr("音声入力・文字起こしの記録")
        case .chat: return tr("エージェント・道具・画像・記録")
        case .models: return tr("スキルを動かすモデル・音声認識")
        case .skills: return tr("声で頼めることの、有効・無効・インストール")
        case .general: return tr("準備状況・基本・アップデート・診断")
        }
    }
}

struct SettingsBadge: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)))
            .shadow(color: colors.last?.opacity(0.35) ?? .clear, radius: 3, y: 1)
    }
}

/// 説明の帯（使い方の例など）。
struct Callout: View {
    let symbol: String
    let text: String
    var tint: Color = Brand.think1

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint).frame(width: 18)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.12)))
    }
}

/// 角丸のカード。題名（小さく）・中身・補足。
struct Card<Content: View>: View {
    let title: String?
    let footer: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.footer = footer; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 6) }
            VStack(alignment: .leading, spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            if let footer { Text(footer).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 6).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 14).opacity(0.7) }
}

/// 1 行：左に題名と説明、右に部品。
struct Row<Trailing: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.detail = detail; self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// キーの見た目（キーボードのキーのように）。
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 10)
            .frame(minWidth: 34, minHeight: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.18)))
            .shadow(color: .black.opacity(0.18), radius: 0, y: 2)
    }
}

/// 状態の小さな札（許可済み・取得済み など）。
struct SettingsPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// ブランドの色のスイッチ（ウィンドウが、アクティブでなくても、同じ色で描く）。
struct BrandSwitch: View {
    let isOn: Binding<Bool>
    var tint: [Color] = [Brand.rec2, Brand.rec1]

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.16)) { isOn.wrappedValue.toggle() } } label: {
            ZStack(alignment: isOn.wrappedValue ? .trailing : .leading) {
                Capsule().fill(isOn.wrappedValue ? AnyShapeStyle(LinearGradient(colors: tint, startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.primary.opacity(0.16)))
                Circle().fill(.white).frame(width: 20, height: 20).shadow(color: .black.opacity(0.28), radius: 1.5, y: 1).padding(2)
            }
            .frame(width: 40, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isOn.wrappedValue ? tr("オン") : tr("オフ")))
    }
}

struct SwitchRow: View {
    @ObservedObject var model: SettingsModel
    let title: String
    let detail: String?
    let value: Bool
    let set: (inout VCCore.Settings, Bool) -> Void
    /// 声の入力を、作り直す（再起動する）設定か。入力のたびに読む設定は、false。
    var restart = true

    init(model: SettingsModel, title: String, detail: String?, value: Bool, restart: Bool = true, set: @escaping (inout VCCore.Settings, Bool) -> Void) {
        self.model = model; self.title = title; self.detail = detail; self.value = value; self.restart = restart; self.set = set
    }

    var body: some View {
        Row(title, detail: detail) {
            BrandSwitch(isOn: Binding(get: { value }, set: { newValue in model.update(restart: restart) { set(&$0, newValue) } }))
        }
    }
}

struct PageHeader: View {
    let page: SettingsPage

    var body: some View {
        HStack(spacing: 14) {
            SettingsBadge(symbol: page.symbol, colors: page.colors, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title).font(.system(size: 22, weight: .bold))
                Text(page.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }
}
