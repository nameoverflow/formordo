import AppKit
import SwiftUI

@main
struct RenderIOSPreviews {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            fputs("Usage: RenderIOSPreviews <output-dir>\n", stderr)
            exit(1)
        }
        let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let dictsURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Dicts", isDirectory: true)
        let bridge = WubiBridge(customDictsDir: dictsURL, inMemoryOnly: true)
        _ = bridge.addUserPhrase("棱五笔", persist: false)

        // Setup iPhone 16 Pro keyboard geometry (`393 x 216`)
        var kbEngine = IOSKeyboardLayoutEngine()
        kbEngine.returnRole = .send
        let portraitSnap = kbEngine.computeLayout(in: CGSize(width: 393, height: 216))
        bridge.setKeyLayout(
            centers52: portraitSnap.centers52,
            originX: portraitSnap.originX,
            originY: portraitSnap.originY,
            pitchX: portraitSnap.pitchX,
            pitchY: portraitSnap.pitchY
        )

        // Train realistic thumb offsets on T, R, I, U, G, H so the 26-key radar map shows genuine learned vectors!
        let tSpec = portraitSnap.keys.first(where: { $0.kind == .letter(UInt8(ascii: "t")) })!
        let ySpec = portraitSnap.keys.first(where: { $0.kind == .letter(UInt8(ascii: "y")) })!
        let rSpec = portraitSnap.keys.first(where: { $0.kind == .letter(UInt8(ascii: "r")) })!
        let wSpec = portraitSnap.keys.first(where: { $0.kind == .letter(UInt8(ascii: "w")) })!
        let uSpec = portraitSnap.keys.first(where: { $0.kind == .letter(UInt8(ascii: "u")) })!

        for round in 0..<5 {
            let ts = UInt64(1000 + round * 400)
            _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "y"), x: Float(ySpec.frame.minX + 1.5), y: Float(tSpec.frame.midY + 2.5), isNormalized: false, timestampMs: ts)
            _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "r"), x: Float(rSpec.frame.midX + 4.0), y: Float(rSpec.frame.midY + 2.0), isNormalized: false, timestampMs: ts + 60)
            _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "w"), x: Float(wSpec.frame.midX - 3.0), y: Float(wSpec.frame.midY + 1.5), isNormalized: false, timestampMs: ts + 120)
            _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "u"), x: Float(uSpec.frame.midX - 4.5), y: Float(uSpec.frame.midY + 2.0), isNormalized: false, timestampMs: ts + 180)
            _ = bridge.selectCandidate(pageRelIndex: 0, timestampMs: ts + 240)
        }

        // Capture live composing state: user taps right border of T (`y`), R, W, and holds finger on `U`!
        _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "y"), x: Float(ySpec.frame.minX + 1.2), y: Float(tSpec.frame.midY + 1.0), isNormalized: false, timestampMs: 5000)
        _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "r"), x: Float(rSpec.frame.midX), y: Float(rSpec.frame.midY), isNormalized: false, timestampMs: 5060)
        _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "w"), x: Float(wSpec.frame.midX), y: Float(wSpec.frame.midY), isNormalized: false, timestampMs: 5120)
        let activeTypoState = bridge.pushTouch(reportedAscii: UInt8(ascii: "u"), x: Float(uSpec.frame.midX), y: Float(uSpec.frame.midY), isNormalized: false, timestampMs: 5180)

        kbEngine.isComposing = true
        let composingSnap = kbEngine.computeLayout(in: CGSize(width: 393, height: 216))

        // 1. iPhone 16 Pro Light — Live Virtual Keyboard with Touch-Border Typo Rescue & Necked Key Callout
        try renderPhoneFrame(
            IPhoneKeyboardDemoScreen(
                isDark: false,
                snapshot: composingSnap,
                state: activeTypoState,
                pressedKey: uSpec,
                touchDot: CGPoint(x: ySpec.frame.minX + 1.2, y: tSpec.frame.midY + 1.0),
                expandedCandidates: nil
            ),
            isDark: false,
            to: outDir.appendingPathComponent("ios-keyboard-typo-light.png")
        )

        // 2. iPhone 16 Pro Dark — Virtual Keyboard Expanded 4-Column Candidate Tray (`khk` / `zguo`)
        bridge.clearComposition()
        bridge.switchSchema(98, persist: false)
        for ch in "zguo".unicodeScalars {
            _ = bridge.handleKey(keyCode: 0, scalar: ch.value, hasCmdOrCtrl: false, timestampMs: 6000)
        }
        let zguoState = bridge.state
        let expandedList = bridge.allCandidates(maxCount: 24)
        kbEngine.schemaId = 98
        let darkSnap = kbEngine.computeLayout(in: CGSize(width: 393, height: 216))

        try renderPhoneFrame(
            IPhoneKeyboardDemoScreen(
                isDark: true,
                snapshot: darkSnap,
                state: zguoState,
                pressedKey: nil,
                touchDot: nil,
                expandedCandidates: expandedList
            ),
            isDark: true,
            to: outDir.appendingPathComponent("ios-keyboard-expanded-dark.png")
        )

        // 3. iPhone 16 Pro Host App — Home & Enable Guide (Light) + 26-Key Touch Hitbox Drift Map (Dark)
        bridge.clearComposition()
        bridge.switchSchema(86, persist: false)
        try renderPhoneFrame(
            IOSHostPhoneShell(isDark: false) {
                IOSHostRootView(bridge: bridge, initialTab: .home)
            },
            isDark: false,
            to: outDir.appendingPathComponent("ios-host-home-light.png")
        )

        try renderPhoneFrame(
            IOSHostPhoneShell(isDark: true) {
                IOSHostRootView(bridge: bridge, initialTab: .typo)
            },
            isDark: true,
            to: outDir.appendingPathComponent("ios-host-hitbox-dark.png")
        )

        print("Rendered 4 Retina iOS previews in \(outDir.path)")
    }

    @MainActor
    static func renderPhoneFrame<V: View>(_ content: V, isDark: Bool, to url: URL) throws {
        let width: CGFloat = 393
        let height: CGFloat = 800
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)!
        let root = content.environment(\.colorScheme, isDark ? .dark : .light)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.appearance = appearance
        win.isOpaque = false
        win.backgroundColor = .clear

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.appearance = appearance
        win.contentView = hosting

        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.14))
        hosting.layoutSubtreeIfNeeded()

        let bounds = hosting.bounds
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * 2),
            pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)
        let png = rep.representation(using: .png, properties: [:])!
        try png.write(to: url)
    }
}

struct IOSHostPhoneShell<Content: View>: View {
    let isDark: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            StatusBarMock(isDark: isDark)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HomeIndicatorBar(isDark: isDark)
                .background(isDark ? Color(red: 0.09, green: 0.09, blue: 0.11) : Color(white: 0.97))
        }
        .background(isDark ? Color(red: 0.09, green: 0.09, blue: 0.11) : Color(white: 0.97))
        .clipShape(RoundedRectangle(cornerRadius: 42, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1.5)
        )
    }
}

struct IPhoneKeyboardDemoScreen: View {
    let isDark: Bool
    let snapshot: IOSKeyboardLayoutEngine.LayoutSnapshot
    let state: WubiActionState
    let pressedKey: IOSKeySpec?
    let touchDot: CGPoint?
    let expandedCandidates: [WubiCandidateItem]?

    var body: some View {
        let pageBg = isDark ? Color(red: 0.07, green: 0.07, blue: 0.09) : Color(red: 0.95, green: 0.96, blue: 0.98)
        let kbBackdrop = isDark ? Color(red: 0.17, green: 0.17, blue: 0.19) : Color(red: 0.82, green: 0.84, blue: 0.87)

        VStack(spacing: 0) {
            StatusBarMock(isDark: isDark)

            // Simulated iOS Messages Header
            HStack {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)
                Spacer()
                VStack(spacing: 1) {
                    Text("棱五笔 · iOS 实机布局")
                        .font(.system(size: 14, weight: .semibold))
                    Text(state.schemaName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "info.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isDark ? Color(white: 0.12) : Color.white.opacity(0.9))

            Divider()

            // Chat conversation context demonstrating bigram & slip rescue
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("手机五笔盲打最怕按到两键缝隙变成空码或者顶上错字")
                        .font(.system(size: 14))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(isDark ? Color(white: 0.18) : Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Spacer(minLength: 48)
                }

                HStack {
                    Spacer(minLength: 52)
                    Text("现在用连续高斯热区 + 5.5 万条语料 Bigram 算后验置信度，滑偏也能直接救回！")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if expandedCandidates != nil {
                    HStack {
                        Text("忘了「国」在 98 五笔怎么拆？首字母敲 zguo 直接反查简码和全码 👇")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.top, 4)
                } else {
                    HStack {
                        Text("👇 首码拇指偏右落进 Y 键边缘（敲出 yrwu），高斯热区自动以 100% 置信度救回「我们」：")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.top, 4)
                }

                Spacer()

                // Composer Input Field
                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        Text("输入法")
                            .font(.system(size: 15))
                        Text(state.preedit)
                            .font(.system(size: 15, design: .monospaced))
                            .underline()
                            .foregroundStyle(.blue)
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: 1.8, height: 18)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(isDark ? Color(white: 0.13) : Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.8)
                    )

                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.blue)
                }
                .padding(.bottom, 8)
            }
            .padding(14)

            // Virtual Keyboard Dock (`44pt` Ribbon + `216pt` Key Canvas + `26pt` Home Bar)
            VStack(spacing: 0) {
                // 44pt Candidate Ribbon
                HStack(spacing: 8) {
                    Text(state.preedit)
                        .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(state.candidates.prefix(4).enumerated()), id: \.element.id) { idx, item in
                                HStack(spacing: 4) {
                                    Text(item.text)
                                        .font(.system(size: 16.5, weight: idx == 0 ? .semibold : .regular))
                                    if !item.comment.isEmpty {
                                        Text(item.comment)
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundStyle(item.badgeKind == .typoCorrected ? Color.orange : Color.secondary)
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(idx == 0 ? Color.primary.opacity(0.11) : Color.clear)
                                )
                            }
                        }
                    }

                    Divider().frame(height: 20)
                    Image(systemName: expandedCandidates != nil ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30)
                }
                .padding(.horizontal, 8)
                .frame(height: 44)

                // 216pt Keyboard Body or Expanded Grid
                ZStack(alignment: .topLeading) {
                    if let expanded = expandedCandidates {
                        ExpandedGridPreview(candidates: expanded, isDark: isDark)
                            .frame(width: 393, height: 216)
                    } else {
                        KeyCanvasPreview(
                            snapshot: snapshot,
                            isDark: isDark,
                            pressedKey: pressedKey,
                            touchDot: touchDot
                        )
                        .frame(width: 393, height: 216)
                    }
                }

                // Bottom iOS Globe / Dictation spacer + Home Indicator
                HomeIndicatorBar(isDark: isDark)
            }
            .background(kbBackdrop)
        }
        .background(pageBg)
        .clipShape(RoundedRectangle(cornerRadius: 42, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1.5)
        )
    }
}

struct KeyCanvasPreview: View {
    let snapshot: IOSKeyboardLayoutEngine.LayoutSnapshot
    let isDark: Bool
    let pressedKey: IOSKeySpec?
    let touchDot: CGPoint?

    var body: some View {
        let regularFill = isDark ? Color(red: 0.42, green: 0.42, blue: 0.44) : Color.white
        let systemFill = isDark ? Color(red: 0.28, green: 0.28, blue: 0.30) : Color(red: 0.68, green: 0.70, blue: 0.74)

        ZStack(alignment: .topLeading) {
            ForEach(snapshot.keys) { spec in
                let fill: Color = spec.isBlueAccent
                    ? Color.blue
                    : (spec.isSystemKey ? systemFill : regularFill)

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(fill)
                    .shadow(color: .black.opacity(isDark ? 0.42 : 0.28), radius: 0.4, x: 0, y: 1.1)
                    .frame(width: spec.frame.width, height: spec.frame.height)
                    .overlay {
                        if let sym = spec.systemSymbol {
                            Image(systemName: sym)
                                .font(.system(size: 16.5, weight: .medium))
                                .foregroundStyle(spec.isBlueAccent ? .white : .primary)
                        } else {
                            Text(spec.primaryLabel)
                                .font(.system(
                                    size: isLetter(spec.kind) ? 21.5 : 14.5,
                                    weight: spec.isBlueAccent ? .semibold : .regular
                                ))
                                .foregroundStyle(spec.isBlueAccent ? .white : .primary)
                        }
                    }
                    .position(x: spec.frame.midX, y: spec.frame.midY)
            }

            // Show subtle orange marker where the slippery first tap landed near T/Y border!
            if let dot = touchDot {
                ZStack {
                    Circle()
                        .strokeBorder(Color.orange, lineWidth: 1.6)
                        .frame(width: 16, height: 16)
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                }
                .position(dot)
            }

            // Authentic Apple iOS Necked Key Callout Bubble!
            if let pk = pressedKey {
                let bw: CGFloat = max(pk.frame.width + 20, 54)
                let bh: CGFloat = pk.frame.height + 54
                ZStack(alignment: .top) {
                    NeckedCalloutShape(baseWidth: pk.frame.width)
                        .fill(isDark ? Color(red: 0.48, green: 0.48, blue: 0.50) : Color.white)
                        .shadow(color: .black.opacity(0.26), radius: 5, x: 0, y: 2)
                    NeckedCalloutShape(baseWidth: pk.frame.width)
                        .stroke(Color.black.opacity(0.12), lineWidth: 0.6)
                    Text(pk.primaryLabel)
                        .font(.system(size: 31, weight: .regular))
                        .padding(.top, 7)
                }
                .frame(width: bw, height: bh)
                .position(x: pk.frame.midX, y: pk.frame.maxY - bh * 0.5)
            }
        }
    }

    private func isLetter(_ k: IOSKeyKind) -> Bool {
        if case .letter = k { return true }
        return false
    }
}

struct NeckedCalloutShape: Shape {
    let baseWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let baseLeft = (w - baseWidth) * 0.5
        let baseRight = baseLeft + baseWidth
        let neckY: CGFloat = 52

        var p = Path()
        p.move(to: CGPoint(x: 10, y: 2))
        p.addLine(to: CGPoint(x: w - 10, y: 2))
        p.addQuadCurve(to: CGPoint(x: w - 2, y: 10), control: CGPoint(x: w - 2, y: 2))
        p.addLine(to: CGPoint(x: w - 2, y: neckY - 12))
        p.addCurve(
            to: CGPoint(x: baseRight, y: neckY + 4),
            control1: CGPoint(x: w - 2, y: neckY - 3),
            control2: CGPoint(x: baseRight, y: neckY - 2)
        )
        p.addLine(to: CGPoint(x: baseRight, y: h - 5))
        p.addQuadCurve(to: CGPoint(x: baseRight - 5, y: h), control: CGPoint(x: baseRight, y: h))
        p.addLine(to: CGPoint(x: baseLeft + 5, y: h))
        p.addQuadCurve(to: CGPoint(x: baseLeft, y: h - 5), control: CGPoint(x: baseLeft, y: h))
        p.addLine(to: CGPoint(x: baseLeft, y: neckY + 4))
        p.addCurve(
            to: CGPoint(x: 2, y: neckY - 12),
            control1: CGPoint(x: baseLeft, y: neckY - 2),
            control2: CGPoint(x: 2, y: neckY - 3)
        )
        p.addLine(to: CGPoint(x: 2, y: 10))
        p.addQuadCurve(to: CGPoint(x: 10, y: 2), control: CGPoint(x: 2, y: 2))
        p.closeSubpath()
        return p
    }
}

struct ExpandedGridPreview: View {
    let candidates: [WubiCandidateItem]
    let isDark: Bool

    var body: some View {
        let cellBg = isDark ? Color(white: 0.28) : Color.white
        HStack(spacing: 6) {
            VStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { col in
                            let idx = row * 3 + col
                            if idx < candidates.count {
                                let item = candidates[idx]
                                VStack(spacing: 2) {
                                    Text(item.text)
                                        .font(.system(size: 16.5, weight: idx == 0 ? .semibold : .regular))
                                    if !item.comment.isEmpty {
                                        Text(item.comment)
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(cellBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                    }
                }
            }

            VStack(spacing: 6) {
                railCell(icon: "chevron.up", text: nil)
                railCell(icon: "delete.left", text: nil)
                railCell(icon: nil, text: "重输")
                railCell(icon: nil, text: "98版")
            }
            .frame(width: 52)
        }
        .padding(6)
    }

    private func railCell(icon: String?, text: String?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.10))
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
            } else if let text {
                Text(text)
                    .font(.system(size: 12.5, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusBarMock: View {
    let isDark: Bool

    var body: some View {
        HStack {
            Text("9:41")
                .font(.system(size: 14.5, weight: .semibold))
                .padding(.leading, 12)
            Spacer()
            Capsule()
                .fill(Color.black)
                .frame(width: 112, height: 30)
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "cellularbars")
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
            }
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.trailing, 8)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }
}

struct HomeIndicatorBar: View {
    let isDark: Bool

    var body: some View {
        VStack {
            Spacer()
            Capsule()
                .fill(Color.primary.opacity(0.35))
                .frame(width: 134, height: 5)
                .padding(.bottom, 7)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 24)
    }
}
