import AppKit
// Crops and enlarges part of a screenshot, e.g. the tab bar: swift tools/crop.swift in.png out.png 0 50 300 32 4
// arguments: <in> <out> x y width height scale   (pixels, top-left origin)
let a = CommandLine.arguments
let img = NSImage(contentsOfFile: a[1])!
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let (x, y, w, h, s) = (Int(a[3])!, Int(a[4])!, Int(a[5])!, Int(a[6])!, Int(a[7])!)
let cg = rep.cgImage!.cropping(to: CGRect(x: x, y: y, width: w, height: h))!
let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * s, pixelsHigh: h * s, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
NSGraphicsContext.current!.imageInterpolation = .none
NSImage(cgImage: cg, size: .zero).draw(in: NSRect(x: 0, y: 0, width: w * s, height: h * s))
NSGraphicsContext.restoreGraphicsState()
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
