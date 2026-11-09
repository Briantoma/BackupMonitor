// Draws the app icon: SS inside a progress ring, on a dark tile.
// Usage: swift tools/make_icon.swift out.png   (1024 x 1024)
import AppKit

let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                  cornerWidth: 186, cornerHeight: 186, transform: nil)
context.saveGState()
context.addPath(tile)
context.clip()
let background = CGGradient(colorsSpace: nil, colors: [color(0x2B2F36), color(0x0B0C0F)] as CFArray,
                            locations: [0, 1])!
context.drawLinearGradient(background, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
context.restoreGState()

let center = CGPoint(x: 512, y: 512)
let radius: CGFloat = 298
let width: CGFloat = 62
context.setLineWidth(width)
context.setLineCap(.round)
context.setStrokeColor(color(0xFFFFFF, 0.12))
context.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
context.strokePath()

// Three quarters of the way round, clockwise from twelve o'clock.
let top = CGFloat.pi / 2
let ring = CGMutablePath()
ring.addArc(center: center, radius: radius, startAngle: top, endAngle: top - .pi * 1.5, clockwise: true)
context.saveGState()
context.addPath(ring.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10))
context.clip()
let progress = CGGradient(colorsSpace: nil, colors: [color(0x5AC8FA), color(0x0A84FF), color(0x30D158)] as CFArray,
                          locations: [0, 0.55, 1])!
context.drawLinearGradient(progress, start: CGPoint(x: 800, y: 800), end: CGPoint(x: 220, y: 240), options: [])
context.restoreGState()

let graphics = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.current = graphics
let font = NSFont.systemFont(ofSize: 300, weight: .heavy)
let text = NSAttributedString(string: "SS", attributes: [
    .font: font, .foregroundColor: NSColor.white, .kern: -10,
])
let bounds = text.size()
text.draw(at: NSPoint(x: 512 - bounds.width / 2 + 2, y: 512 - bounds.height / 2 + 4))

let image = context.makeImage()!
let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
