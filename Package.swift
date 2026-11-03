// swift-tools-version:6.2
import PackageDescription

// ターゲットの依存の向きは、ここで宣言し、コンパイラが強制する（宣言していない依存の `import` は、`--explicit-target-dependency-import-check=error` を付けたビルドで失敗する。付けない差分ビルドは、警告だけのことがある。scripts/test.sh・scripts/package.sh・just build は付けている）。
//   VCCore ← VCDecision ← VCSkill・VCPCControl、 VCCore ← VCSpeech （VCSkill・VCPCControl・VCSpeech は、互いに依存しない）
let package = Package(
    name: "voice-control",
    platforms: [.macOS("26.0")],
    targets: [
        // 設定・置き場所・取りやめの合図。どのターゲットも使ってよい。
        .target(name: "VCCore", path: "Sources/VCCore"),
        // 選択（Chooser・Gate）とモデル（ModelStore）。Tiny-Jev の実行（MPSGraph。Decision/）は meeting-analyzer からの複製を含む（docs/architecture.md）。
        .target(name: "VCDecision", dependencies: ["VCCore"], path: "Sources/VCDecision"),
        // 音声入力（ホットキー・録音・文字起こし）。
        .target(name: "VCSpeech", dependencies: ["VCCore"], path: "Sources/VCSpeech"),
        // スキル（SKILL.md の読み込み・ルーティング・コマンドの実行）。
        .target(name: "VCSkill", dependencies: ["VCCore", "VCDecision"], path: "Sources/VCSkill"),
        // PC 操作（画面の読み取り・計画・実行）。
        .target(name: "VCPCControl", dependencies: ["VCCore", "VCDecision"], path: "Sources/VCPCControl"),
        // 試す用の CLI（アプリではない）。
        .executableTarget(name: "vc", dependencies: ["VCCore", "VCDecision", "VCSpeech", "VCSkill", "VCPCControl"], path: "Sources/vc"),
        // 検証用の自作ウィンドウ（ボタン・入力欄・スクロール領域・状態を持つ部品）。
        .executableTarget(name: "Fixture", path: "Sources/Fixture"),
        .testTarget(name: "VCCoreTests", dependencies: ["VCCore"], path: "Tests/VCCoreTests"),
        .testTarget(name: "VCDecisionTests", dependencies: ["VCCore", "VCDecision"], path: "Tests/VCDecisionTests"),
        .testTarget(name: "VCSpeechTests", dependencies: ["VCCore", "VCSpeech"], path: "Tests/VCSpeechTests"),
        .testTarget(name: "VCSkillTests", dependencies: ["VCCore", "VCDecision", "VCSkill", "VCSpeech"], path: "Tests/VCSkillTests"),
        .testTarget(name: "VCPCControlTests", dependencies: ["VCCore", "VCDecision", "VCPCControl"], path: "Tests/VCPCControlTests"),
    ],
    swiftLanguageModes: [.v5]
)
