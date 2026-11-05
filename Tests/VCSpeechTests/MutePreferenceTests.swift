import Testing
@testable import VCSpeech

/// 録音中に、ほかの音を消すか：その実行のオプション → 設定 → 既定（消す）の順。
@Suite struct MutePreferenceTests {
    @Test func theDefaultIsToMute() {
        #expect(MutePreference.resolve(flag: nil, setting: nil))
    }

    @Test func theSettingOverridesTheDefault() {
        #expect(!MutePreference.resolve(flag: nil, setting: false))
        #expect(MutePreference.resolve(flag: nil, setting: true))
    }

    /// その実行のオプションは、設定より優先する（設定が off でも `--mute` で消せる。on でも `--no-mute` で流せる）。
    @Test func theFlagOverridesTheSetting() {
        #expect(MutePreference.resolve(flag: true, setting: false))
        #expect(!MutePreference.resolve(flag: false, setting: true))
    }
}
