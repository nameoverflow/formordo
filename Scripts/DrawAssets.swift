import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("Usage: DrawAssets <app-icon-png> <menu-icon-pdf> [ios-icon-png]\n", stderr)
    exit(1)
}

let iconOut = URL(fileURLWithPath: args[1])
let menuOut = URL(fileURLWithPath: args[2])

func continuousSquirclePath(in rect: CGRect, radius: CGFloat) -> CGPath {
    let p = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let path = CGMutablePath()
    var points = [NSPoint](repeating: .zero, count: 3)
    for i in 0..<p.elementCount {
        let type = p.element(at: i, associatedPoints: &points)
        switch type {
        case .moveTo: path.move(to: points[0])
        case .lineTo: path.addLine(to: points[0])
        case .curveTo, .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
        case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
        case .closePath: path.closeSubpath()
        @unknown default: break
        }
    }
    return path
}

func drawNibEmblem(in ctx: CGContext, rect: CGRect, primary: CGColor, accent: CGColor, isMenu: Bool) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.minY)
    ctx.scaleBy(x: rect.width / 100.0, y: rect.height / 100.0)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let nib = CGMutablePath()
    nib.move(to: CGPoint(x: 50, y: 86))
    nib.addLine(to: CGPoint(x: 78, y: 46))
    nib.addLine(to: CGPoint(x: 68, y: 22))
    nib.addLine(to: CGPoint(x: 32, y: 22))
    nib.addLine(to: CGPoint(x: 22, y: 46))
    nib.closeSubpath()

    if isMenu {
        // Outer rounded-square keycap matching Apple native input method menu icons
        let framePath = continuousSquirclePath(in: CGRect(x: 6, y: 9, width: 88, height: 82), radius: 20)
        ctx.addPath(framePath)
        ctx.setStrokeColor(primary)
        ctx.setLineWidth(7.5)
        ctx.strokePath()

        // Pure-vector even-odd nib silhouette with hollow ink slit & breather eye (no blend modes in PDF)
        let nibCutout = CGMutablePath()
        nibCutout.move(to: CGPoint(x: 50, y: 74))
        nibCutout.addLine(to: CGPoint(x: 70, y: 46))
        nibCutout.addLine(to: CGPoint(x: 63, y: 26))
        nibCutout.addLine(to: CGPoint(x: 37, y: 26))
        nibCutout.addLine(to: CGPoint(x: 30, y: 46))
        nibCutout.closeSubpath()

        // Inner slit + breather circle as non-overlapping subpaths for clean even-odd cutout
        nibCutout.addPath(continuousSquirclePath(in: CGRect(x: 47.2, y: 53.0, width: 5.6, height: 15.0), radius: 2.0))
        nibCutout.addEllipse(in: CGRect(x: 43.5, y: 39.0, width: 13.0, height: 13.0))

        ctx.addPath(nibCutout)
        ctx.setFillColor(primary)
        ctx.fillPath(using: .evenOdd)
    } else {
        ctx.addPath(nib)
        ctx.setFillColor(primary)
        ctx.fillPath()

        // Vermilion ink slit & breather eye
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(4.5)
        ctx.move(to: CGPoint(x: 50, y: 85))
        ctx.addLine(to: CGPoint(x: 50, y: 51))
        ctx.strokePath()

        ctx.setFillColor(accent)
        ctx.fillEllipse(in: CGRect(x: 43.5, y: 41.5, width: 13, height: 13))

        // Base collar bar
        ctx.setFillColor(primary)
        ctx.addPath(continuousSquirclePath(in: CGRect(x: 30, y: 11, width: 40, height: 7), radius: 3.5))
        ctx.fillPath()
    }

    ctx.restoreGState()
}

// iOS supplies its own mask. Use the same emblem on an opaque, full-bleed tile.
func renderIcon(to output: URL, forIOS: Bool) throws {
    let size = 1024
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = nsCtx
    let ctx = nsCtx.cgContext
    let cs = CGColorSpaceCreateDeviceRGB()

    let rect = forIOS ? CGRect(x: 0, y: 0, width: size, height: size) : CGRect(x: 96, y: 96, width: 832, height: 832)
    let squircle = continuousSquirclePath(in: rect, radius: forIOS ? 0 : rect.width * 0.225)

    // Subtle macOS icon drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 34, color: CGColor(gray: 0, alpha: 0.18))
    ctx.addPath(squircle)
    ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let colors = [
        CGColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1.0),
        CGColor(red: 0.91, green: 0.89, blue: 0.85, alpha: 1.0),
    ] as CFArray
    let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(
        grad,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.minY),
        options: []
    )

    let glyphRect = rect.insetBy(dx: rect.width * 0.17, dy: rect.height * 0.17)
    drawNibEmblem(
        in: ctx,
        rect: glyphRect,
        primary: CGColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1.0),
        accent: CGColor(red: 0.86, green: 0.27, blue: 0.21, alpha: 1.0),
        isMenu: false
    )

    // Crisp inner specular rim
    ctx.addPath(squircle)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.72))
    ctx.setLineWidth(6.0)
    if !forIOS { ctx.strokePath() }

    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()

    var bitmap = rep
    if forIOS {
        let opaque = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                               bytesPerRow: size * 4, space: cs,
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        opaque.draw(rep.cgImage!, in: rect)
        bitmap = NSBitmapImageRep(cgImage: opaque.makeImage()!)
    }
    let png = bitmap.representation(using: .png, properties: [:])!
    try png.write(to: output)
}

try renderIcon(to: iconOut, forIOS: false)
if args.count > 3 { try renderIcon(to: URL(fileURLWithPath: args[3]), forIOS: true) }

// 2. Render 18x18 Vector Template PDF for macOS Menu Bar
do {
    final class MenuIconView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            drawNibEmblem(
                in: ctx,
                rect: bounds,
                primary: NSColor.black.cgColor,
                accent: NSColor.black.cgColor,
                isMenu: true
            )
        }
    }
    let v = MenuIconView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
    let pdf = v.dataWithPDF(inside: v.bounds)
    try pdf.write(to: menuOut)
}
