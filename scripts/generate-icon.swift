//
//  generate-icon.swift
//  Renders the 1024×1024 master app icon: dark editor-canvas squircle, white play
//  triangle, yellow trim handles (the app's own visual identity).
//
//  Usage: swift scripts/generate-icon.swift <output.png>
//

import AppKit

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon-master.png"

let canvas = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("could not create bitmap context")
}
NSGraphicsContext.current = context
let cg = context.cgContext

// macOS icon grid: 824×824 squircle centered on a 1024 canvas, soft drop shadow.
let box = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: box, xRadius: 186, yRadius: 186)

cg.saveGState()
cg.setShadow(
    offset: CGSize(width: 0, height: -14), blur: 28,
    color: NSColor.black.withAlphaComponent(0.35).cgColor
)
NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
squircle.fill()
cg.restoreGState()

// Canvas gradient: charcoal fading to near-black, like the editor window.
cg.saveGState()
squircle.addClip()
NSGradient(colors: [
    NSColor(calibratedRed: 0.24, green: 0.24, blue: 0.27, alpha: 1),
    NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 1),
])!.draw(in: box, angle: -90)

// Faint top edge highlight for depth.
let highlight = NSBezierPath(roundedRect: box.insetBy(dx: 3, dy: 3), xRadius: 183, yRadius: 183)
highlight.lineWidth = 6
NSColor.white.withAlphaComponent(0.07).setStroke()
highlight.stroke()
cg.restoreGState()

// Yellow trim handles — the app's trim strip grips, complete with white grip lines.
let yellow = NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.04, alpha: 1)
let handleSize = NSSize(width: 52, height: 330)
let gripSize = NSSize(width: 10, height: 84)
for centerX: CGFloat in [296, 728] {
    let handleRect = NSRect(
        x: centerX - handleSize.width / 2, y: 512 - handleSize.height / 2,
        width: handleSize.width, height: handleSize.height
    )
    cg.saveGState()
    cg.setShadow(
        offset: CGSize(width: 0, height: -6), blur: 14,
        color: NSColor.black.withAlphaComponent(0.45).cgColor
    )
    yellow.setFill()
    NSBezierPath(roundedRect: handleRect, xRadius: 18, yRadius: 18).fill()
    cg.restoreGState()

    let gripRect = NSRect(
        x: centerX - gripSize.width / 2, y: 512 - gripSize.height / 2,
        width: gripSize.width, height: gripSize.height
    )
    NSColor.white.withAlphaComponent(0.9).setFill()
    NSBezierPath(roundedRect: gripRect, xRadius: 5, yRadius: 5).fill()
}

// White play triangle between the handles. Fill + fat round-joined stroke of the
// same color = rounded corners without hand-building arc segments.
let triangle = NSBezierPath()
triangle.move(to: NSPoint(x: 452, y: 636))
triangle.line(to: NSPoint(x: 452, y: 388))
triangle.line(to: NSPoint(x: 662, y: 512))
triangle.close()
triangle.lineWidth = 44
triangle.lineJoinStyle = .round

// Shadow pass first, then a clean fill+stroke — stroking inside the shadowed state
// would cast the stroke's shadow onto the fill and etch a ghost triangle into it.
cg.saveGState()
cg.setShadow(
    offset: CGSize(width: 0, height: -8), blur: 18,
    color: NSColor.black.withAlphaComponent(0.5).cgColor
)
NSColor.white.setFill()
triangle.fill()
cg.restoreGState()
NSColor.white.setFill()
NSColor.white.setStroke()
triangle.fill()
triangle.stroke()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode png")
}
try! png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
