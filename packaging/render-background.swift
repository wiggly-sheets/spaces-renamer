// Renders packaging/background.png for the Spaces Renamer DMG.
//
// Usage: swift render-background.swift [OUTPUT]
//
// Artwork: a restrained cool-grey gradient with matching source and destination
// cards plus centered drag instructions. Finder positions icons using a
// top-left origin, while AppKit draws the background from the bottom-left; the
// card geometry accounts for that difference so the live icons and labels sit
// squarely inside both cards.
//
// Output is deterministic: drawn into a fixed 1600x900 (2x) bitmap
// regardless of the display the build machine has, so regenerating always
// produces the same pixels. The generated PNG is committed; regeneration is
// only needed when the layout changes.

import AppKit

let outputPath = CommandLine.arguments.count > 1
  ? CommandLine.arguments[1]
  : "background.png"

let width: CGFloat = 800
let height: CGFloat = 450
let scale: CGFloat = 2

guard let rep = NSBitmapImageRep(
  bitmapDataPlanes: nil,
  pixelsWide: Int(width * scale),
  pixelsHigh: Int(height * scale),
  bitsPerSample: 8,
  samplesPerPixel: 4,
  hasAlpha: true,
  isPlanar: false,
  colorSpaceName: .deviceRGB,
  bytesPerRow: 0,
  bitsPerPixel: 0
) else {
  fatalError("failed to create bitmap")
}
// Point size of the drawing surface; the context maps these points onto the
// 1600x900 pixel grid above.
rep.size = NSSize(width: width, height: height)

guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
  fatalError("failed to create graphics context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
defer {
  ctx.flushGraphics()
  NSGraphicsContext.restoreGraphicsState()
}

let cg = ctx.cgContext

// Background gradient: a subtle cool grey that lets the purple app icon carry
// the color without leaving the installer looking stark or unfinished.
let colors = [
  NSColor(calibratedRed: 0.925, green: 0.930, blue: 0.950, alpha: 1).cgColor,
  NSColor(calibratedRed: 0.985, green: 0.985, blue: 0.992, alpha: 1).cgColor,
] as CFArray
let gradient = CGGradient(
  colorsSpace: CGColorSpaceCreateDeviceRGB(),
  colors: colors,
  locations: [0, 1]
)!
cg.drawLinearGradient(
  gradient,
  start: CGPoint(x: 0, y: 0),
  end: CGPoint(x: 0, y: height),
  options: []
)

func drawCentered(_ text: String, font: NSFont, color: NSColor, center: NSPoint) {
  let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: color,
  ]
  let string = text as NSString
  let textSize = string.size(withAttributes: attributes)
  string.draw(
    at: NSPoint(
      x: center.x - textSize.width / 2,
      y: center.y - textSize.height / 2
    ),
    withAttributes: attributes
  )
}

// Title.
drawCentered(
  "Spaces Renamer",
  font: .systemFont(ofSize: 31, weight: .semibold),
  color: NSColor(calibratedWhite: 0.20, alpha: 1),
  center: NSPoint(x: width / 2, y: 397)
)

func drawCard(centerX: CGFloat) {
  let rect = CGRect(x: centerX - 98, y: 130, width: 196, height: 210)
  let path = CGPath(
    roundedRect: rect,
    cornerWidth: 18,
    cornerHeight: 18,
    transform: nil
  )

  cg.saveGState()
  cg.setShadow(
    offset: CGSize(width: 0, height: -2),
    blur: 10,
    color: NSColor(calibratedWhite: 0.20, alpha: 0.13).cgColor
  )
  cg.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.72).cgColor)
  cg.addPath(path)
  cg.fillPath()
  cg.restoreGState()

  cg.setStrokeColor(
    NSColor(calibratedRed: 0.47, green: 0.40, blue: 0.72, alpha: 0.30).cgColor
  )
  cg.setLineWidth(1)
  cg.addPath(path)
  cg.strokePath()
}

// Finder places both items at y=190 from the top of the window. These equal
// cards contain each live icon and its Finder-rendered label on one baseline.
drawCard(centerX: 200)
drawCard(centerX: 600)

// Centered instruction and arrow form a compact third column between the two
// matching cards.
drawCentered(
  "Drag to Applications",
  font: .systemFont(ofSize: 16, weight: .medium),
  color: NSColor(calibratedWhite: 0.32, alpha: 1),
  center: NSPoint(x: 400, y: 282)
)

let arrowY: CGFloat = 236
let arrowStartX: CGFloat = 330
let arrowEndX: CGFloat = 470
cg.setStrokeColor(
  NSColor(calibratedRed: 0.43, green: 0.36, blue: 0.68, alpha: 0.72).cgColor
)
cg.setLineWidth(2.5)
cg.setLineCap(.round)
cg.move(to: CGPoint(x: arrowStartX, y: arrowY))
cg.addLine(to: CGPoint(x: arrowEndX, y: arrowY))
cg.strokePath()
cg.setFillColor(
  NSColor(calibratedRed: 0.43, green: 0.36, blue: 0.68, alpha: 0.72).cgColor
)
cg.move(to: CGPoint(x: arrowEndX, y: arrowY))
cg.addLine(to: CGPoint(x: arrowEndX - 12, y: arrowY - 7))
cg.addLine(to: CGPoint(x: arrowEndX - 12, y: arrowY + 7))
cg.closePath()
cg.fillPath()

guard let png = rep.representation(using: .png, properties: [:]) else {
  fatalError("failed to encode PNG")
}
try! png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
