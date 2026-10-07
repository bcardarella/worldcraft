// Reproducible, original iPad app icon. Run from the repository root with Swift.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: "Resources/Assets.xcassets/AppIconIPad.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096,
  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }
func polygon(_ points: [CGPoint], _ fill: CGColor) {
  context.setFillColor(fill); context.beginPath(); context.addLines(between: points)
  context.closePath(); context.fillPath()
}
context.setFillColor(color(0.045, 0.16, 0.19)); context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.setFillColor(color(0.99, 0.76, 0.32)); context.fillEllipse(in: CGRect(x: 694, y: 714, width: 118, height: 118))
polygon([CGPoint(x: 176,y: 476),CGPoint(x: 512,y: 284),CGPoint(x: 848,y: 476),CGPoint(x: 512,y: 668)], color(0.015,0.10,0.14))
polygon([CGPoint(x: 176,y: 524),CGPoint(x: 512,y: 332),CGPoint(x: 512,y: 138),CGPoint(x: 176,y: 330)], color(0.40,0.25,0.15))
polygon([CGPoint(x: 512,y: 332),CGPoint(x: 848,y: 524),CGPoint(x: 848,y: 330),CGPoint(x: 512,y: 138)], color(0.57,0.35,0.19))
polygon([CGPoint(x: 176,y: 574),CGPoint(x: 512,y: 382),CGPoint(x: 512,y: 314),CGPoint(x: 176,y: 506)], color(0.22,0.52,0.20))
polygon([CGPoint(x: 512,y: 382),CGPoint(x: 848,y: 574),CGPoint(x: 848,y: 506),CGPoint(x: 512,y: 314)], color(0.32,0.66,0.24))
polygon([CGPoint(x: 176,y: 574),CGPoint(x: 512,y: 766),CGPoint(x: 848,y: 574),CGPoint(x: 512,y: 382)], color(0.49,0.78,0.29))
for (x,y): (CGFloat,CGFloat) in [(380,590),(476,645),(572,590),(476,535)] {
  polygon([CGPoint(x:x,y:y),CGPoint(x:x+48,y:y+28),CGPoint(x:x+96,y:y),CGPoint(x:x+48,y:y-28)], color(0.56,0.84,0.34))
}
let image = context.makeImage()!
let output = CGImageDestinationCreateWithURL(directory.appendingPathComponent("Icon.png") as CFURL,
  UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(output, image, nil)
precondition(CGImageDestinationFinalize(output))
let contents = """
{"images":[{"filename":"Icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
"""
try contents.write(to: directory.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
