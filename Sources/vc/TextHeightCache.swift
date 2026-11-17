import CoreGraphics
import Foundation

/// 文章の高さの記憶（幅と文字が同じなら、測り直さない）。答えの高さを測るには、文章全体を組み直す（`NSLayoutManager`）ので、レイアウトのたびに呼ばれると、長い答え・表で重い。
/// 書式が違っても、文字が同じなら、同じ高さになる前提（同じ文字は、同じ Markdown から、同じ書式で描く）。
enum TextHeightCache {
    private static let cache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 400
        return cache
    }()

    static func height(width: CGFloat, text: String, measure: () -> CGFloat) -> CGFloat {
        // 幅は、無限（理想の幅の問い合わせ）・非数のことがある：`Int` にできないので、文字にしてから（クラッシュした）
        let key = "\(width.isFinite ? String(Int(width.rounded())) : "unbounded")|\(UIScale.currentSize)|\(text)" as NSString   // 文字の大きさが変わったら、別の高さ
        if let known = cache.object(forKey: key) { return CGFloat(known.doubleValue) }
        let height = measure()
        cache.setObject(NSNumber(value: Double(height)), forKey: key)
        return height
    }
}
