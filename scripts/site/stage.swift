import AppKit
// 撮影用の、自作の背景（壁紙のように見える。画面の内容を、写さないため）。引数：top（画面の上の中央）か center（画面の中央）。標準出力：撮る範囲（左上が原点）
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "center"
let seconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 30 : 30
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!
let vf = screen.visibleFrame
let w: CGFloat = CommandLine.arguments.count > 3 ? CGFloat(Double(CommandLine.arguments[3]) ?? 960) : 960
let h: CGFloat = CommandLine.arguments.count > 4 ? CGFloat(Double(CommandLine.arguments[4]) ?? 540) : 540
let y = mode == "top" ? vf.maxY - h : vf.midY - h / 2
let rect = NSRect(x: vf.midX - w / 2, y: y, width: w, height: h)
let win = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
win.level = NSWindow.Level(rawValue: 24)
win.isOpaque = true
win.backgroundColor = NSColor(calibratedRed: 0.045, green: 0.05, blue: 0.09, alpha: 1)
let view = NSView(frame: NSRect(origin: .zero, size: rect.size)); view.wantsLayer = true
view.layer = CALayer(); view.layer!.backgroundColor = win.backgroundColor.cgColor
func orb(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: NSColor) {
    let g = CAGradientLayer(); g.type = .radial
    g.frame = NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
    g.colors = [c.withAlphaComponent(0.85).cgColor, c.withAlphaComponent(0).cgColor]
    g.startPoint = CGPoint(x: 0.5, y: 0.5); g.endPoint = CGPoint(x: 1, y: 1)
    view.layer!.addSublayer(g)
}
orb(w * 0.18, h * 0.80, 380, NSColor(calibratedRed: 0.20, green: 0.42, blue: 0.95, alpha: 1))
orb(w * 0.82, h * 0.30, 420, NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.85, alpha: 1))
orb(w * 0.55, h * 0.05, 300, NSColor(calibratedRed: 0.10, green: 0.70, blue: 0.75, alpha: 1))
win.contentView = view
win.orderFrontRegardless()
let top = screen.frame.maxY - rect.maxY
print("\(Int(rect.minX)),\(Int(top)),\(Int(w)),\(Int(h))"); fflush(stdout)
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
app.run()
