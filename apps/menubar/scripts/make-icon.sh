#!/usr/bin/env bash
# make-icon.sh — render AppIcon.icns (a split-circle "severance" glyph in the
# Lumon navy/cyan palette) with Core Graphics + iconutil. Output: $1 (an .icns
# path). No external assets or design tools required.
set -euo pipefail

OUT="${1:?usage: make-icon.sh <path/to/AppIcon.icns>}"
work="$(mktemp -d)"
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"

swift - "$iconset" <<'SWIFT'
import AppKit

let outDir = CommandLine.arguments[1]

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext
    let s = CGFloat(px)

    // Rounded navy background with a subtle vertical gradient.
    let bg = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                    cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
    ctx.saveGState()
    ctx.addPath(bg); ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.05, green: 0.14, blue: 0.22, alpha: 1),
        CGColor(red: 0.02, green: 0.06, blue: 0.11, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    let cx = s / 2, cy = s / 2, r = s * 0.28
    let cyan = CGColor(red: 0.62, green: 0.91, blue: 1.0, alpha: 1)

    // Left half of the disc filled (the innie); right half stays open (the outie).
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: cx, height: s))
    ctx.setFillColor(cyan)
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.fillPath()
    ctx.restoreGState()

    // Full ring around the disc.
    ctx.setStrokeColor(cyan)
    ctx.setLineWidth(max(1, s * 0.045))
    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // The sever: a navy divider down the middle.
    ctx.setStrokeColor(CGColor(red: 0.03, green: 0.08, blue: 0.14, alpha: 1))
    ctx.setLineWidth(max(1, s * 0.03))
    ctx.move(to: CGPoint(x: cx, y: cy - r - s * 0.02))
    ctx.addLine(to: CGPoint(x: cx, y: cy + r + s * 0.02))
    ctx.strokePath()

    gctx.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    let data = render(base * scale)
    try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}
SWIFT

iconutil -c icns "$iconset" -o "$OUT"
rm -rf "$work"
echo "wrote $OUT"
