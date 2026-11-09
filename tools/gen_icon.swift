// Draws the app icon to a PNG with the bundled reading font. The Paper artboard
// "App icon" is the design, and these values are read from it.
//
//     swift tools/gen_icon.swift gui/Fonts out.png
import AppKit
import CoreText

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("usage: gen_icon.swift <fonts-dir> <out.png>") }

let canvas: CGFloat = 1024
let tile: CGFloat = 824
let corner: CGFloat = 185
let fontSize: CGFloat = 380
let ground = NSColor(srgbRed: 0x0A / 255, green: 0x3C / 255, blue: 1, alpha: 1)

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

let inset = (canvas - tile) / 2
ground.setFill()
NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: tile, height: tile), xRadius: corner, yRadius: corner).fill()

let text = NSAttributedString(string: "fyke", attributes: [.font: font, .foregroundColor: NSColor.white, .kern: -0.03 * fontSize])
let size = text.size()
text.draw(at: NSPoint(x: (canvas - size.width) / 2, y: (canvas - size.height) / 2 + 20))

NSGraphicsContext.current = nil
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(filePath: arguments[2]))
