import AppKit

// 生成黑白 waveform 图标（黑色圆角底 + 白色波形）
// 用法: swift gen_icon.swift <输出.png路径>
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()

// 黑色圆角底
let corner: CGFloat = size * 0.22
NSColor.black.setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
             xRadius: corner, yRadius: corner).fill()

// 白色 waveform（用 paletteColors 强制白色）
let symbolSize = size * 0.60
let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = sym.size
    let rect = NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2,
                      width: s.width, height: s.height)
    sym.draw(in: rect)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("icon generated: \(outPath)")
