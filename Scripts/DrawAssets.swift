import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("Usage: DrawAssets <app-icon-png> <menu-icon-pdf>\n", stderr)
    exit(1)
}

let iconOut = URL(fileURLWithPath: args[1])
let menuOut = URL(fileURLWithPath: args[2])

// 1. Render 1024x1024 macOS App Icon
do {
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
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 96, y: 96, width: 832, height: 832)
    let path = NSBezierPath(roundedRect: rect, xRadius: 190, yRadius: 190)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.08, green: 0.45, blue: 0.92, alpha: 1.0),
        NSColor(calibratedRed: 0.05, green: 0.25, blue: 0.68, alpha: 1.0),
    ])!
    gradient.draw(in: path, angle: -55)

    // Subtle keycap inner frame
    let keyRect = rect.insetBy(dx: 68, dy: 68)
    let keyPath = NSBezierPath(roundedRect: keyRect, xRadius: 136, yRadius: 136)
    NSColor.white.withAlphaComponent(0.12).setFill()
    keyPath.fill()
    NSColor.white.withAlphaComponent(0.24).setStroke()
    keyPath.lineWidth = 6
    keyPath.stroke()

    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 450, weight: .bold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: para,
    ]
    let str = NSAttributedString(string: "五", attributes: attrs)
    let strSize = str.size()
    let strRect = NSRect(
        x: (1024 - strSize.width) / 2,
        y: (1024 - strSize.height) / 2 - 14,
        width: strSize.width,
        height: strSize.height
    )
    str.draw(in: strRect)

    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: iconOut)
}

// 2. Render 18x18 Vector Template PDF for macOS Menu Bar
do {
    final class MenuIconView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.2, dy: 1.8), xRadius: 3.5, yRadius: 3.5)
            NSColor.black.setStroke()
            border.lineWidth = 1.3
            border.stroke()

            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.2, weight: .semibold),
                .foregroundColor: NSColor.black,
                .paragraphStyle: para,
            ]
            let s = NSAttributedString(string: "五", attributes: attrs)
            let sz = s.size()
            s.draw(in: NSRect(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2 - 0.3, width: sz.width, height: sz.height))
        }
    }
    let v = MenuIconView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
    let pdf = v.dataWithPDF(inside: v.bounds)
    try pdf.write(to: menuOut)
}
