import Foundation
import VCCore

/// Tiny-Jev 0.6B のモデル（取得先・置き場所）。取得と検証の仕組みは、`VCCore` の `ModelStore`。
public enum TinyJevModel {
    /// Tiny-Jev 0.6B。値は meeting-analyzer の `DecisionModelCatalog` と同じ（Hugging Face `lostargon/Tiny-Jev`・版 `62449fb`）。
    public static let spec = ModelSpec(
        name: "tiny-jev-0.6b",
        baseURL: URL(string: "https://huggingface.co/lostargon/Tiny-Jev/resolve/62449fb3272d68fb8c8fe8a33082566643a76d0b")!,
        files: [
            ModelFile(name: "tokenizer.json", bytes: 11_422_832, sha256: "e3fccc77adda606e2a461ffd17ca5a55a5a75ac40a5aa0a91c5307fb31b1efac"),
            ModelFile(name: "model.safetensors", bytes: 1_191_594_564, sha256: "513411b17cb0eca54839ca3948b4353e7f65710723ffcde8d13e3cb04328633e"),
        ]
    )

    public static var defaultDirectory: URL { ModelStore.defaultDirectory(for: spec) }
    public static func isInstalled(in directory: URL) -> Bool { ModelStore.isInstalled(spec, in: directory) }
}
