import AppKit
import CoreText

// Legacy icon generator; the app now uses the supplied Affinity PNG artwork.
// Running this script replaces that artwork with the old Newsreader icon.
let side = 1024
let cg = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
    bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
NSColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: side, height: side).fill()
let fontURL = URL(fileURLWithPath: "tools/fonts/Newsreader-Italic.ttf")
let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL)! as! [CTFontDescriptor])[0]
// Newsreader Italic, regular weight with display optical sizing.
let variations: [NSNumber: NSNumber] = [0x77676874: 400, 0x6F70737A: 72]
let displayDescriptor = CTFontDescriptorCreateCopyWithAttributes(descriptor,
    [kCTFontVariationAttribute: variations] as CFDictionary)
let font = CTFontCreateWithFontDescriptor(displayDescriptor, 860, nil)
let text = NSAttributedString(string: "b.", attributes: [
    .font: font, .foregroundColor: NSColor(red: 0.12, green: 0.22, blue: 0.19, alpha: 1)
])
let line = CTLineCreateWithAttributedString(text)
let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
cg.textPosition = CGPoint(x: (1024 - bounds.width) / 2 - bounds.minX,
                          y: (1024 - bounds.height) / 2 - bounds.minY)
CTLineDraw(line, cg)
NSGraphicsContext.restoreGraphicsState()
let bitmap = NSBitmapImageRep(cgImage: cg.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to:
    URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
