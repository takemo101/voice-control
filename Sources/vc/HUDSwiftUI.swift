import AppKit
import SwiftUI

// 画面の上のパネル（`HUD`）の中身（SwiftUI）。Liquid Glass のカード・状態の色のにじみ・動く部品（波形・脈打つ輪・考え中のドット・光が流れる題・ばねで弾むバッジ）。
// 窓の管理（位置・フェード・Space・キー・クリックを通すか）は、`HUD`（AppKit）。ここは、描くだけ。
// SwiftUI の `@State` は、この環境（コマンドラインツールだけ）では、マクロのプラグインがなく使えない：状態は、参照型（`HUDModel`・`@StateObject`）に置く。

/// 描く状態（`HUD` が、更新する）。
@MainActor final class HUDModel: ObservableObject {
    /// 確認のボタンの、キーボードの選択：0 = 実行する、1 = やめる（最初は「やめる」：ほかのアプリで打っている最中の Return が、実行にならないように）。
    @Published var focusedChoice = 1
    /// 録音を始めた時刻（経過時間）。
    var recordingStart = Date()
    var waveform = WaveformState()
    /// 録音中に聞こえている文字（途中経過。`LiveCaptioner`）。なければ、案内の文を出す。録音の段階だけ。
    @Published var liveText: LiveCaptionText?
    /// 本文が、高さの上限を超えたか（超えたら、スクロールのために、クリックを受ける）。
    var onBodyOverflow: ((Bool) -> Void)?

    /// 録音の段階に入るとき、経過時間と波形を、最初から。
    func beginRecording() {
        recordingStart = Date()
        waveform = WaveformState()
    }
}

/// 録音中の波形の状態：右が、いまの音量。左へ流れる。静かなときも、わずかに息づく（動いていないように見えないため）。
/// 時刻から、30 回/秒の歩みで進める（描くたびに、進んだぶんだけ）。メインスレッドだけで触る。
@MainActor final class WaveformState {
    static let count = 30
    private var history = [Float](repeating: 0, count: WaveformState.count)
    private var peak: Float = 0
    private var phase = 0.0
    private var lastStep: TimeInterval?

    /// 音量（0〜1）を受け取る。次の歩みまでの最大を、使う。
    func push(_ level: Float) { peak = max(peak, level) }

    var latest: Float { history.last ?? 0 }

    func bars(at now: Date) -> [Float] {
        let t = now.timeIntervalSinceReferenceDate
        guard let last = lastStep else { lastStep = t; return history }
        let steps = min(4, Int((t - last) * 30))
        if steps > 0 {
            lastStep = last + Double(steps) / 30
            for _ in 0..<steps { advance() }
        }
        return history
    }

    private func advance() {
        phase += 0.14
        let idle = 0.07 + 0.035 * Float(sin(phase))
        let target = max(peak, idle)
        peak *= 0.5
        let smoothed = (history.last ?? 0) * 0.4 + target * 0.6
        history.removeFirst()
        history.append(smoothed)
    }
}

/// 出た時刻（ばねの動きの起点）。出るたびに、作り直す（`.id`）。
@MainActor private final class Born: ObservableObject { let date = Date() }

private enum Palette {
    static let rec1 = Color(red: 1.0, green: 0.30, blue: 0.28)
    static let rec2 = Color(red: 1.0, green: 0.62, blue: 0.20)
    static let think1 = Color(red: 0.40, green: 0.82, blue: 1.0)
    static let think2 = Color(red: 0.72, green: 0.42, blue: 0.98)
    static let ok = Color(red: 0.30, green: 0.85, blue: 0.52)
    static let warn = Color(red: 1.0, green: 0.80, blue: 0.25)
    static let bad = Color(red: 1.0, green: 0.36, blue: 0.36)

    static func tint(_ content: HUDContent) -> Color {
        if content.choices { return warn }
        switch content.phase {
        case .recording, .failure: return content.phase == .recording ? rec1 : bad
        case .working: return think2
        case .success: return ok
        case .confirm: return warn
        case .info: return .white
        }
    }
}

/// 影（にじみ）のための、カードの外側の余白。窓は、カード + この余白。
let hudShadowMargin: CGFloat = 30
let hudCardWidth: CGFloat = 468
let hudCompactWidth: CGFloat = 376
/// 本文（ステップ・返事）の高さの上限。超えたら、スクロール。
let hudMaxBodyHeight: CGFloat = 300

// MARK: ルート

struct HUDRootView: View {
    let content: HUDContent
    @ObservedObject var model: HUDModel
    let answer: (Bool) -> Void

    var body: some View {
        Group {
            if content.isCompact { CompactCard(content: content, model: model) } else { FullCard(content: content, model: model, answer: answer) }
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: 入れ物

/// ガラスのカード：暗いガラス・細い光の縁・状態の色のにじみ。
private struct GlassCard<Content: View>: View {
    let tint: Color
    let radius: CGFloat
    let width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(.horizontal, 20).padding(.vertical, 14)
            .frame(width: width, alignment: .leading)
            .glassEffect(.regular.tint(tint.opacity(0.10)), in: shape)
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.06), tint.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
            .shadow(color: tint.opacity(0.35), radius: 22, y: 6)
            .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
            .padding(hudShadowMargin)
    }
}

// MARK: 小さなカプセル（録音中・認識中）

private struct CompactCard: View {
    let content: HUDContent
    @ObservedObject var model: HUDModel

    var body: some View {
        let captioned = content.phase == .recording && content.captionSlot   // 録音中の文字の欄を出す（`vc caption`）
        GlassCard(tint: Palette.tint(content), radius: captioned ? 28 : 30, width: captioned ? hudCardWidth : hudCompactWidth) {
            VStack(alignment: .leading, spacing: captioned ? 12 : 6) {
                if content.phase == .recording { recording } else { thinking }
                if captioned {
                    CaptionPlate(live: model.liveText, hint: content.hint)
                } else if let hint = content.hint {
                    Text(hint).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.tail)
                }
            }
        }
    }

    private var recording: some View {
        HStack(spacing: 12) {
            TimelineView(.animation) { tl in
                MicOrb(t: tl.date.timeIntervalSinceReferenceDate, level: model.waveform.latest)
            }
            TimelineView(.animation) { tl in
                Waveform(bars: model.waveform.bars(at: tl.date)).frame(maxWidth: .infinity).frame(height: 28)
            }
            TimelineView(.periodic(from: .now, by: 0.25)) { tl in
                let seconds = max(0, Int(tl.date.timeIntervalSince(model.recordingStart)))
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.9))
            }
            if let chip = content.chip { Pill(text: chip) }
        }
    }

    private var thinking: some View {
        HStack(spacing: 12) {
            TimelineView(.animation) { tl in ThinkingDots(t: tl.date.timeIntervalSinceReferenceDate) }
            TimelineView(.animation) { tl in ShimmerText(text: content.title, t: tl.date.timeIntervalSinceReferenceDate) }
            Spacer(minLength: 4)
            if let chip = content.chip { Pill(text: chip) }
        }
    }
}

/// 録音中に聞こえている文字の欄（字幕のような板）：確定した文字は白く、確定前の文字は薄く。末尾に、点滅するカーソル。2 行まで（新しい言葉が見えるように、先頭から切る）。
/// 文字が来るまでは、案内の文を、薄く出す。欄の高さは、いつも 2 行分（文字が増えても、パネルの大きさが、変わらない）。
private struct CaptionPlate: View {
    let live: LiveCaptionText?
    let hint: String?
    /// 1 行に収まる文字数の目安（欄の幅 約 400pt・15.5pt の字）。2 行分。
    private let maxCharacters = 50

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        HStack(alignment: .top, spacing: 10) {
            Capsule().fill(LinearGradient(colors: [Palette.rec2, Palette.rec1], startPoint: .top, endPoint: .bottom)).frame(width: 3)
                .opacity(live?.isEmpty == false ? 0.95 : 0.35)
            if let live, !live.isEmpty {
                TimelineView(.periodic(from: .now, by: 0.5)) { tl in
                    let caretOn = Int(tl.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                    captionText(live, caretOn: caretOn)
                }
            } else {
                Text(hint ?? "話してください…").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.5)).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .background(shape.fill(LinearGradient(colors: [Palette.rec1.opacity(0.10), .white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.7))
        .animation(.easeOut(duration: 0.18), value: live)
    }

    private func captionText(_ live: LiveCaptionText, caretOn: Bool) -> some View {
        let t = live.tail(maxCharacters: maxCharacters)
        let text = Text(t.truncated ? "…" : "").foregroundStyle(Color.white.opacity(0.4))
            + Text(t.confirmed).foregroundStyle(Color.white)
            + Text(t.tentative).foregroundStyle(Color.white.opacity(0.55))
            + Text("▎").foregroundStyle(caretOn ? Palette.rec2 : Color.clear)
        return text.font(.system(size: 15.5, weight: .medium)).lineSpacing(4).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 波形：右が、いまの音量。古い（左の）ほど薄く、音量が大きいほど濃い。
private struct Waveform: View {
    let bars: [Float]
    var body: some View {
        Canvas { ctx, size in
            let n = bars.count
            guard n > 1 else { return }
            let barWidth: CGFloat = 3
            let gap = max(1, (size.width - CGFloat(n) * barWidth) / CGFloat(n - 1))
            let gradient = GraphicsContext.Shading.linearGradient(Gradient(colors: [Palette.rec1, Palette.rec2]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
            for (i, value) in bars.enumerated() {
                let v = CGFloat(value)
                let h = max(3, v * size.height * 0.95)
                let rect = CGRect(x: CGFloat(i) * (barWidth + gap), y: (size.height - h) / 2, width: barWidth, height: h)
                let age: CGFloat = CGFloat(i) / CGFloat(n - 1)
                let loud: CGFloat = min(1, 0.35 + v)
                let alpha: CGFloat = 0.25 + 0.75 * loud * (0.35 + 0.65 * age)
                var layer = ctx
                layer.opacity = Double(alpha)
                layer.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: gradient)
            }
        }
    }
}

/// 録音中の印：赤い点と、広がって消える輪（音量で、少し大きく）。
private struct MicOrb: View {
    let t: Double
    let level: Float
    var body: some View {
        ZStack {
            ForEach(0..<2) { k in
                let p = (t * 0.9 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                Circle().stroke(Palette.rec1.opacity(0.55 * (1 - p)), lineWidth: 1.4).scaleEffect(0.55 + (0.95 + Double(level) * 0.5) * p)
            }
            Circle().fill(RadialGradient(colors: [Palette.rec2, Palette.rec1], center: .topLeading, startRadius: 1, endRadius: 14)).frame(width: 13, height: 13)
                .shadow(color: Palette.rec1.opacity(0.8), radius: 6)
        }.frame(width: 26, height: 26)
    }
}

/// 考え中のドット：波打つ。
private struct ThinkingDots: View {
    let t: Double
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                let p = 0.5 + 0.5 * sin(t * 5 - Double(i) * 0.9)
                Circle().fill(LinearGradient(colors: [Palette.think1, Palette.think2], startPoint: .top, endPoint: .bottom))
                    .frame(width: 7, height: 7).scaleEffect(0.65 + 0.5 * p).opacity(0.5 + 0.5 * p).offset(y: -3 * p)
            }
        }.frame(width: 30)
    }
}

/// 光が流れる題（考え中）。
private struct ShimmerText: View {
    let text: String
    let t: Double
    var body: some View {
        let x = (t * 0.45).truncatingRemainder(dividingBy: 1.6) - 0.3
        Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            .overlay(
                Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: x - 0.2), .init(color: .white, location: x), .init(color: .clear, location: x + 0.2)], startPoint: .leading, endPoint: .trailing))
            )
    }
}

private struct Pill: View {
    let text: String
    var tint: Color = .white
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint.opacity(0.85)).lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.14)))
            .fixedSize()
    }
}

// MARK: 本体のカード（実行の経過・結果・確認）

private struct FullCard: View {
    let content: HUDContent
    @ObservedObject var model: HUDModel
    let answer: (Bool) -> Void

    var body: some View {
        let tint = Palette.tint(content)
        GlassCard(tint: tint, radius: 24, width: hudCardWidth) {
            VStack(alignment: .leading, spacing: 10) {
                header(tint: tint)
                if let image = content.image { ImageRow(image: image, large: content.choices && image.sendsOut) }
                if hasBody { bodyContent }
                if content.choices { choices }
            }
        }
    }

    private var hasBody: Bool { content.hint != nil || (content.heard?.isEmpty == false) || !content.steps.isEmpty || (content.reply?.isEmpty == false) }

    private func header(tint: Color) -> some View {
        HStack(spacing: 10) {
            if content.phase == .working {
                TimelineView(.animation) { tl in ThinkingDots(t: tl.date.timeIntervalSinceReferenceDate) }
            } else {
                Badge(symbol: symbol, tint: tint).id(content.title + String(describing: content.phase))
            }
            Text(content.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
            if let skill = content.skill { Pill(text: skill, tint: Palette.think1) }
            Spacer(minLength: 8)
            if let chip = content.chip { Pill(text: chip) }
        }
    }

    private var symbol: String {
        switch content.phase {
        case .recording: return "mic.fill"
        case .success: return "checkmark"
        case .failure: return "xmark"
        case .confirm: return "questionmark"
        default: return "info"
        }
    }

    /// 補足・聞こえた文・コマンド・返事。長いときは、ここだけが、スクロールする（見出しは、動かない）。最新（下）から見せる。
    private var bodyContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                if let hint = content.hint { Text(hint).font(.system(size: 12)).foregroundStyle(.white.opacity(0.62)).fixedSize(horizontal: false, vertical: true) }
                if let heard = content.heard, !heard.isEmpty {
                    Text("“\(heard)”").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(2).truncationMode(.tail)
                }
                if !content.steps.isEmpty || content.reply != nil {
                    Rectangle().fill(.white.opacity(0.15)).frame(height: 0.7)
                }
                ForEach(Array(content.steps.enumerated()), id: \.offset) { _, step in StepRow(step: step) }
                if let reply = content.reply, !reply.isEmpty {
                    Text(reply).font(.system(size: 14, weight: .medium)).foregroundStyle(.white).lineLimit(5).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { proxy in Color.clear.preference(key: BodyHeightKey.self, value: proxy.size.height) })
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .frame(maxHeight: hudMaxBodyHeight)
        .onPreferenceChange(BodyHeightKey.self) { height in model.onBodyOverflow?(height > hudMaxBodyHeight + 0.5) }
    }

    private var choices: some View {
        HStack(spacing: 10) {
            ChoiceButton(title: "実行する", tint: Palette.ok, prominent: true, focused: model.focusedChoice == 0) { answer(true) }
            ChoiceButton(title: "やめる", tint: .white, prominent: false, focused: model.focusedChoice == 1) { answer(false) }
        }
        .padding(.top, 2)
    }
}

/// 使う画像：サムネイルと、大きさ・どこで処理するか。見た目は、画像のパネル（`ImageCardView`）に合わせる（角丸 12・細い縁・影・カプセルのチップ）。
/// 外へ送る画像が、確認に出ているときは、大きく見せる（何を送るのかを、見分けるため）。
private struct ImageRow: View {
    let image: HUDImage
    let large: Bool

    /// 画像の縦横の比を保って、枠（普通は 120 × 68・確認のときは 260 × 150）に収めた大きさ（枠を、画像にぴったり合わせる：縁と影が、画像の形になる）。
    private var fitted: CGSize {
        let box = large ? CGSize(width: 260, height: 150) : CGSize(width: 120, height: 68)
        let scale = min(box.width / max(image.pixelSize.width, 1), box.height / max(image.pixelSize.height, 1))
        return CGSize(width: (image.pixelSize.width * scale).rounded(), height: (image.pixelSize.height * scale).rounded())
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: image.thumbnail).resizable()
                .frame(width: fitted.width, height: fitted.height)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.38), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 6) {
                Pill(text: "\(Int(image.pixelSize.width)) × \(Int(image.pixelSize.height))")
                if image.sendsOut { Pill(text: "外へ送る画像", tint: Palette.warn) } else { Pill(text: "この Mac の中だけ", tint: Palette.ok) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct BodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 状態の印（丸い面に、ばねで弾むアイコン）。
private struct Badge: View {
    let symbol: String
    let tint: Color
    @StateObject private var born = Born()

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSince(born.date)
            // 減衰する振動：0.35 → 1.0 を、行き過ぎて戻る
            let k = t > 1.2 ? 1.0 : 1 - exp(-7 * t) * cos(13 * t)
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 28, height: 28)
                Image(systemName: symbol).font(.system(size: 14, weight: .bold)).foregroundStyle(tint)
                    .scaleEffect(0.35 + 0.65 * k).opacity(min(1, t * 8))
            }
        }
    }
}

private struct StepRow: View {
    let step: HUDContent.Step

    var body: some View {
        let (glyph, tint) = mark
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(glyph).font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
                Text(step.command).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.92)).lineLimit(1).truncationMode(.middle)
            }
            if let output = step.output, !output.isEmpty {
                Text(output).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.55)).padding(.leading, 18).lineLimit(1).truncationMode(.tail)
            }
        }
    }

    private var mark: (String, Color) {
        switch step.status {
        case .running: return ("▸", Palette.think1)
        case .ok: return ("✓", Palette.ok)
        case .failed: return ("✗", Palette.bad)
        case .denied: return ("⊘", Color(red: 1.0, green: 0.62, blue: 0.2))
        }
    }
}

/// 確認のボタン：自分で描く（パネルは、キーのない状態でも出る：標準のボタンは、薄く見える）。focused：キーボードの選択（外側に、細い輪）。
private struct ChoiceButton: View {
    let title: String
    let tint: Color
    let prominent: Bool
    let focused: Bool
    let action: () -> Void

    var body: some View {
        let shape = Capsule()
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(shape.fill(prominent ? AnyShapeStyle(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.70)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.white.opacity(0.14))))
                .overlay(shape.strokeBorder(.white.opacity(prominent ? 0.35 : 0.18), lineWidth: 0.7))
                .overlay(shape.inset(by: -3).stroke(.white.opacity(focused ? 0.75 : 0), lineWidth: 1.6))
                .shadow(color: prominent ? tint.opacity(0.45) : .clear, radius: 8, y: 2)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
