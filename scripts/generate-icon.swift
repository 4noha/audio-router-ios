// 1024x1024 のシンプルなアプリアイコン (青地に "AR" 白文字) を生成する。
// 使い方: swift scripts/generate-icon.swift <出力 PNG パス>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreText

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: generate-icon.swift <out.png>\n".data(using: .utf8)!)
    exit(2)
}
let outPath = args[1]

let size: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}

// 背景グラデーション (深い青)
let colors: [CGColor] = [
    CGColor(red: 0.10, green: 0.20, blue: 0.55, alpha: 1.0),
    CGColor(red: 0.22, green: 0.45, blue: 0.85, alpha: 1.0)
]
let grad = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad,
                       start: CGPoint(x: 0, y: 0),
                       end: CGPoint(x: 0, y: size),
                       options: [])

// 中央に AR の白文字 (CoreText 直叩き、UIKit 不要)
let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 540, nil)
let attrs: [CFString: Any] = [
    kCTFontAttributeName: font,
    kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
]
let txt = NSAttributedString(string: "AR", attributes: attrs as [NSAttributedString.Key: Any])
let line = CTLineCreateWithAttributedString(txt)
let bounds = CTLineGetImageBounds(line, ctx)
ctx.textPosition = CGPoint(
    x: (size - bounds.width) / 2 - bounds.minX,
    y: (size - bounds.height) / 2 - bounds.minY)
CTLineDraw(line, ctx)

guard let img = ctx.makeImage() else { exit(1) }
let url = URL(fileURLWithPath: outPath)
guard let dest = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
print("wrote \(outPath)")
