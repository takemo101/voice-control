// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "voice-control",
    platforms: [.macOS("26.0")],
    targets: [
        // スキル・PC 操作・音声・選択の部品。Tiny-Jev の実行（MPSGraph。Decision/）は meeting-analyzer からの複製を含む（docs/architecture.md）。
        .target(name: "VCCore", path: "Sources/VCCore"),
        .target(name: "VCDecision", dependencies: ["VCCore"], path: "Sources/VCDecision"),
        .target(name: "VCSpeech", dependencies: ["VCCore"], path: "Sources/VCSpeech"),
        .target(name: "VoiceControlKit", dependencies: ["VCCore", "VCDecision", "VCSpeech"], path: "Sources/VoiceControlKit"),
        // 試す用の CLI（アプリではない）。
        .executableTarget(name: "vc", dependencies: ["VoiceControlKit", "VCCore", "VCDecision", "VCSpeech"], path: "Sources/vc"),
        // 検証用の自作ウィンドウ（ボタン・入力欄・スクロール領域・状態を持つ部品）。
        .executableTarget(name: "Fixture", path: "Sources/Fixture"),
        .testTarget(name: "VoiceControlKitTests", dependencies: ["VoiceControlKit", "VCCore", "VCDecision", "VCSpeech"], path: "Tests/VoiceControlKitTests"),
    ],
    swiftLanguageModes: [.v5]
)
