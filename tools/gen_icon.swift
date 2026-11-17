// Draws the app icon to a PNG with the bundled reading font: a Newsreader "f" whose
// period is the unread dot, in the accent blue on a light tile.
//
//     swift tools/gen_icon.swift gui/Fonts out.png
import AppKit
import CoreText

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("usage: gen_icon.swift <fonts-dir> <out.png>") }

// Geometry on a 1024 canvas, origin at the bottom left.
let canvas: CGFloat = 1024
let tile: CGFloat = 824
let corner: CGFloat = 185
let fontSize: CGFloat = 660
let letterCenterX: CGFloat = 460
let baseline: CGFloat = 282
let dotCenter = CGPoint(x: 650, y: 312)
let dotRadius: CGFloat = 44

let accent = CGColor(srgbRed: 0x0A / 255, green: 0x3C / 255, blue: 1, alpha: 1)
let tileTop = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
let tileBottom = CGColor(srgbRed: 0xEE / 255, green: 0xF1 / 255, blue: 0xF7 / 255, alpha: 1)
let tileEdge = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08)

let fontFile = URL(filePath: arguments[1]).appending(path: "Newsreader[opsz,wght].ttf")
CTFontManagerRegisterFontURLs([fontFile] as CFArray, .process, true, nil)
let variation = NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
let weightAxis = 0x7767_6874
let opticalAxis = 0x6F70_737A
let descriptor = NSFontDescriptor(fontAttributes: [.family: "Newsreader", variation: [weightAxis: 600, opticalAxis: 72]])
let font = NSFont(descriptor: descriptor, size: fontSize)!

let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas), bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext

let inset = (canvas - tile) / 2
let shape = CGPath(
    roundedRect: CGRect(x: inset, y: inset, width: tile, height: tile),
    cornerWidth: corner, cornerHeight: corner, transform: nil)
context.saveGState()
context.addPath(shape)
context.clip()
let gradient = CGGradient(colorsSpace: nil, colors: [tileTop, tileBottom] as CFArray, locations: [0, 1])!
context.drawLinearGradient(
    gradient, start: CGPoint(x: 0, y: inset + tile), end: CGPoint(x: 0, y: inset), options: [])
context.restoreGState()
context.addPath(shape)
context.setStrokeColor(tileEdge)
context.setLineWidth(2)
context.strokePath()

let letter = NSAttributedString(string: "f", attributes: [.font: font, .foregroundColor: NSColor(cgColor: accent)!])
let line = CTLineCreateWithAttributedString(letter)
let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
context.textPosition = CGPoint(x: letterCenterX - advance / 2, y: baseline)
CTLineDraw(line, context)

context.setFillColor(accent)
context.fillEllipse(in: CGRect(
    x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))

NSGraphicsContext.current = nil
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(filePath: arguments[2]))
