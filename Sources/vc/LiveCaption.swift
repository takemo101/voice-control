import AVFoundation
import Foundation
import VCSpeech

/// 録音中の文字（途中経過）を、画面の上のパネルに出す（`vc caption`。実験。F54）。録音の始まりで、リアルタイムの認識（`LiveCaptioner`）を始め、認識の段階・取りやめで、終える。
/// **表示だけ**：最終の文字・実行は、いつもどおり、録音したファイルの認識（`FileTranscriber`）。失敗しても、表示が出ないだけ。
/// `@unchecked Sendable` の理由：可変な状態は、すべて `lock` で守る。`feed` は、音声のスレッドから呼ばれる。
final class LiveCaption: @unchecked Sendable {
    static let shared = LiveCaption()
    private let lock = NSLock()
    private var captioner: LiveCaptioner?
    private var isEnabled = true

    /// 使うか（設定 `liveCaption`。聞き始める前に、決める）。
    func enable(_ on: Bool) { lock.withLock { isEnabled = on } }

    /// 録音の始まり：認識を始める（前のものが残っていれば、終える）。
    func begin() {
        let (enabled, old): (Bool, LiveCaptioner?) = lock.withLock { (isEnabled, captioner) }
        old?.finish()
        guard enabled else { lock.withLock { captioner = nil }; return }
        let next = LiveCaptioner { text in HUD.shared.pushLiveText(text) }
        lock.withLock { captioner = next }
        next.start()
    }

    /// マイクの入力を渡す（音声のスレッドから）。
    func feed(_ buffer: AVAudioPCMBuffer) {
        let current = lock.withLock { captioner }
        current?.feed(buffer)
    }

    /// 録音の終わり・取りやめ：認識を終える。
    func end() {
        let current: LiveCaptioner? = lock.withLock { let c = captioner; captioner = nil; return c }
        current?.finish()
    }
}
