import Foundation

/// 複数のトリガー（例：Shift の長押し＝声で頼む、Ctrl の長押し＝音声入力）を、1 つにまとめる。
/// - **どれか 1 つを押している間だけ**録音する。別のトリガーを押しても、録音中は無視する（マイクは 1 つ。離した印も、押したほうのものだけを受ける）。
/// - 録音を始めたトリガーの印（`tag`）を、`VoiceLoop` が、出来事と発話の処理へ渡す。`tag` は、押している間と、離した直後（`onRelease` の中）は、そのトリガーのもの。
@MainActor public final class ModeTrigger: TaggedTrigger {
    public var onPress: (@Sendable () -> Void)?
    public var onRelease: (@Sendable () -> Void)?
    public private(set) var tag = ""
    private var active: String?
    private let triggers: [PushToTalkTrigger]

    public init(_ triggers: [(tag: String, trigger: PushToTalkTrigger)]) {
        self.triggers = triggers.map(\.trigger)
        for (tag, trigger) in triggers {
            trigger.onPress = { [weak self] in MainActor.assumeIsolated { self?.press(tag) } }
            trigger.onRelease = { [weak self] in MainActor.assumeIsolated { self?.release(tag) } }
        }
    }

    private func press(_ pressed: String) {
        guard active == nil else { return }   // 別のトリガーで、録音中
        active = pressed
        tag = pressed
        onPress?()
    }

    private func release(_ released: String) {
        guard active == released else { return }   // 押していないトリガーの「離した」
        onRelease?()
        active = nil
    }
}
