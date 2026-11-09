// Draws the app icon: a stack of three drives inside a progress ring, on a dark tile.
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

// Back drive on top, front drive lightest at the bottom; the front one's light is green.
let drive = CGSize(width: 326, height: 88)
let gap: CGFloat = 20
for (index, shade) in [0x8A8F98, 0xB9BDC4, 0xE4E6EA].enumerated() {
    let y = 512 + (drive.height + gap) * (1 - CGFloat(index)) - drive.height / 2
    let body = CGRect(x: 512 - drive.width / 2, y: y, width: drive.width, height: drive.height)
    context.setFillColor(color(UInt32(shade)))
    context.addPath(CGPath(roundedRect: body, cornerWidth: 26, cornerHeight: 26, transform: nil))
    context.fillPath()
    context.setFillColor(index == 2 ? color(0x30D158) : color(0x23262B))
    context.fillEllipse(in: CGRect(x: body.maxX - 66, y: body.midY - 12, width: 24, height: 24))
}

let image = context.makeImage()!
let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
