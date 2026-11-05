import Foundation

/// 録音中に、ほかの音を消すか：`--mute`・`--no-mute`（その実行だけ）→ 設定（`vc mute`）→ 既定（消す）。
public enum MutePreference {
    public static func resolve(flag: Bool?, setting: Bool?) -> Bool { flag ?? setting ?? true }
}
