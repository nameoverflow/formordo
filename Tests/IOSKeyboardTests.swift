import CoreGraphics
import Foundation

@main
struct IOSKeyboardTests {
    @MainActor
    static func main() {
        // 1. Verify exact iOS 26 440pt Pro Max grid alignment against Apple reference telemetry!
        var layout = IOSKeyboardLayoutEngine()
        let snap = layout.computeLayout(in: CGSize(width: 440, height: 225))
        assert(snap.keys.count == 32, "Expected 26 letters + Shift + Del + 4 bottom keys = 32, got \(snap.keys.count)")

        let qKey = snap.keys.first(where: { $0.kind == .letter(UInt8(ascii: "q")) })!
        assert(qKey.primaryLabel == "q", "Expected lowercase 'q' in iOS 26 default mode, got \(qKey.primaryLabel)")
        assert(abs(qKey.frame.width - 37.27) < 0.25, "Expected ~37.27pt key width on 440pt canvas, got \(qKey.frame.width)")

        // Verify column-for-column invariants: `z` == `s`, `Space` == `d..j`, `Return` == `k..p`!
        let sKey = snap.keys.first(where: { $0.kind == .letter(UInt8(ascii: "s")) })!
        let dKey = snap.keys.first(where: { $0.kind == .letter(UInt8(ascii: "d")) })!
        let jKey = snap.keys.first(where: { $0.kind == .letter(UInt8(ascii: "j")) })!
        let kKey = snap.keys.first(where: { $0.kind == .letter(UInt8(ascii: "k")) })!
        let zKey = snap.keys.first(where: { $0.kind == .letter(UInt8(ascii: "z")) })!
        let spaceKey = snap.keys.first(where: { $0.kind == .space })!
        let returnKey = snap.keys.first(where: { $0.kind == .returnKey })!

        assert(abs(zKey.frame.minX - sKey.frame.minX) < 0.01, "z.minX must equal s.minX")
        assert(abs(spaceKey.frame.minX - dKey.frame.minX) < 0.01, "Space.minX must equal d.minX")
        assert(abs(spaceKey.frame.maxX - jKey.frame.maxX) < 0.01, "Space.maxX must equal j.maxX")
        assert(abs(returnKey.frame.minX - kKey.frame.minX) < 0.01, "Return.minX must equal k.minX")
        assert(spaceKey.cornerSubscript == "五", "Spacebar must show subtle corner '五'")
        assert(returnKey.systemSymbol == "return.left", "Normal return key must use return.left symbol")

        // 2. Test Voronoi gutter hit-testing
        let tKey = snap.keys.first(where: { $0.kind == .letter(UInt8(ascii: "t")) })!
        let yKey = snap.keys.first(where: { $0.kind == .letter(UInt8(ascii: "y")) })!
        let gutterMid = CGPoint(x: (tKey.frame.maxX + yKey.frame.minX) * 0.5 - 0.5, y: tKey.frame.midY)
        let gutterHit = IOSKeyboardLayoutEngine.hitTest(point: gutterMid, in: snap)
        assert(gutterHit?.kind == .letter(UInt8(ascii: "t")))

        // 3. Test Shift -> Uppercase (`Q`) -> Double-tap CapsLock -> Lowercase (`q`)
        layout.tapShift(at: 10.0)
        assert(layout.shiftState == .upperOnce)
        let upperSnap = layout.computeLayout(in: CGSize(width: 440, height: 225))
        let upperQ = upperSnap.keys.first(where: { $0.kind == .letter(UInt8(ascii: "q")) })!
        assert(upperQ.primaryLabel == "Q")
        layout.tapShift(at: 10.20)
        assert(layout.shiftState == .capsLocked)
        layout.tapShift(at: 11.0)
        assert(layout.shiftState == .lower)

        // 4. Test Numbers (123) and Symbols (#+=) planes + native stay-vs-return rules
        layout.switchPlane(.numbers)
        let numSnap = layout.computeLayout(in: CGSize(width: 440, height: 220))
        assert(numSnap.keys.contains(where: { $0.primaryLabel == "1" }))
        assert(numSnap.keys.contains(where: { $0.primaryLabel == "，" }))
        assert(numSnap.keys.contains(where: { $0.primaryLabel == "." }))
        assert(!IOSKeyboardLayoutEngine.shouldReturnToLettersAfterSymbol("5", on: .numbers))
        assert(!IOSKeyboardLayoutEngine.shouldReturnToLettersAfterSymbol("-", on: .numbers))
        assert(!IOSKeyboardLayoutEngine.shouldReturnToLettersAfterSymbol("/", on: .numbers))
        assert(!IOSKeyboardLayoutEngine.shouldReturnToLettersAfterSymbol("：", on: .numbers))
        assert(!IOSKeyboardLayoutEngine.shouldReturnToLettersAfterSymbol(".", on: .numbers))
        assert(!IOSKeyboardLayoutEngine.shouldReturnToLettersAfterSymbol("￥", on: .numbers))
        assert(IOSKeyboardLayoutEngine.shouldReturnToLettersAfterSymbol("，", on: .numbers))
        assert(IOSKeyboardLayoutEngine.shouldReturnToLettersAfterSymbol("。", on: .numbers))
        assert(IOSKeyboardLayoutEngine.shouldReturnToLettersAfterSymbol("（", on: .numbers))
        assert(IOSKeyboardLayoutEngine.shouldReturnToLettersAfterSymbol("；", on: .numbers))
        layout.switchPlane(.symbols)
        let symSnap = layout.computeLayout(in: CGSize(width: 440, height: 220))
        assert(symSnap.keys.contains(where: { $0.primaryLabel == "《" }))
        assert(!IOSKeyboardLayoutEngine.shouldReturnToLettersAfterSymbol("～", on: .symbols))
        assert(!IOSKeyboardLayoutEngine.shouldReturnToLettersAfterSymbol("…", on: .symbols))
        assert(IOSKeyboardLayoutEngine.shouldReturnToLettersAfterSymbol("《", on: .symbols))
        assert(IOSKeyboardLayoutEngine.shouldReturnToLettersAfterSymbol("+", on: .symbols))
        layout.switchPlane(.letters)

        // 5. Test Spacebar Trackpad Cursor Accumulator
        var trackpad = SpaceTrackpadAccumulator()
        trackpad.begin(at: 180.0)
        assert(trackpad.update(x: 200.0) == 2)
        assert(trackpad.update(x: 189.0) == -1)
        trackpad.end()

        // 6. Test end-to-end iOS 26 view coordinates -> Rust wubi-core touch slip rescue & drift learning!
        let dictsURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Dicts", isDirectory: true)
        let bridge = WubiBridge(customDictsDir: dictsURL, inMemoryOnly: true)
        bridge.setKeyLayout(
            centers52: snap.centers52,
            originX: snap.originX,
            originY: snap.originY,
            pitchX: snap.pitchX,
            pitchY: snap.pitchY
        )

        let rKey = snap.keys.first(where: { $0.kind == .letter(UInt8(ascii: "r")) })!
        let wKey = snap.keys.first(where: { $0.kind == .letter(UInt8(ascii: "w")) })!
        let uKey = snap.keys.first(where: { $0.kind == .letter(UInt8(ascii: "u")) })!

        let borderPoint = CGPoint(x: yKey.frame.minX + 1.2, y: tKey.frame.midY + 1.5)
        _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "y"), x: Float(borderPoint.x), y: Float(borderPoint.y), isNormalized: false, timestampMs: 1000)
        _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "r"), x: Float(rKey.frame.midX), y: Float(rKey.frame.midY), isNormalized: false, timestampMs: 1070)
        _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "w"), x: Float(wKey.frame.midX), y: Float(wKey.frame.midY), isNormalized: false, timestampMs: 1140)
        let out = bridge.pushTouch(reportedAscii: UInt8(ascii: "u"), x: Float(uKey.frame.midX), y: Float(uKey.frame.midY), isNormalized: false, timestampMs: 1210)
        assert(out.candidates.first?.text == "我们", "Expected iOS 26 view-space touch slip rescue '我们'")

        // 7. Verify clean typographic mode toggle key (`中/英`), ergonomic downward Y-bias,
        //    and dynamic Wubi valid-next-key hitbox expansion!
        let modeKey = snap.keys.first(where: { $0.kind == .modeToggle })!
        assert(modeKey.primaryLabel == "中" && modeKey.secondaryInlineLabel == "/英" && modeKey.systemSymbol == nil)

        // Ergonomic thumb bias: tapping 2.2pt below `g`'s bottom edge (inside Row 1 -> Row 2 gutter) stays on `g`!
        let gKey = snap.keys.first(where: { $0.kind == .letter(UInt8(ascii: "g")) })!
        let lowThumbTap = CGPoint(x: gKey.frame.midX, y: gKey.frame.maxY + 6.5)
        let biasedHit = IOSKeyboardLayoutEngine.hitTest(point: lowThumbTap, in: snap)
        assert(biasedHit?.kind == .letter(UInt8(ascii: "g")), "Expected ergonomic thumb Y-bias to keep low tap on 'g'")

        // Dynamic next-key hitbox expansion: after typing "trw", 'u' is valid in Wubi 86 while 'i' is dead!
        bridge.clearComposition()
        _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "t"), x: Float(tKey.frame.midX), y: Float(tKey.frame.midY), isNormalized: false, timestampMs: 2000)
        _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "r"), x: Float(rKey.frame.midX), y: Float(rKey.frame.midY), isNormalized: false, timestampMs: 2060)
        let afterTrw = bridge.pushTouch(reportedAscii: UInt8(ascii: "w"), x: Float(wKey.frame.midX), y: Float(wKey.frame.midY), isNormalized: false, timestampMs: 2120)
        let iKey = snap.keys.first(where: { $0.kind == .letter(UInt8(ascii: "i")) })!
        let uBit = UInt32(1) << UInt32(UInt8(ascii: "u") - UInt8(ascii: "a"))
        let iBit = UInt32(1) << UInt32(UInt8(ascii: "i") - UInt8(ascii: "a"))
        assert((afterTrw.validNextMask & uBit) != 0 && (afterTrw.validNextMask & iBit) == 0, "Expected 'u' valid and 'i' invalid after 'trw'")

        // Tap 2.4pt inside `i`'s left border: dynamic hitbox expansion snaps cleanly to valid 'u' and auto-commits "我们"!
        let edgeInsideI = CGPoint(x: iKey.frame.minX + 2.4, y: uKey.frame.midY)
        let dynHit = IOSKeyboardLayoutEngine.hitTest(point: edgeInsideI, in: snap, validNextMask: afterTrw.validNextMask)
        assert(dynHit?.kind == .letter(UInt8(ascii: "u")), "Expected dynamic hitbox expansion to snap border tap inside 'i' onto valid 'u'")
        let commitOut = bridge.pushTouch(reportedAscii: UInt8(ascii: "u"), x: Float(edgeInsideI.x), y: Float(edgeInsideI.y), isNormalized: false, timestampMs: 2180)
        assert(commitOut.commitText == "我们", "Expected clean 4-code auto-commit '我们' via dynamic next-key expansion, got '\(commitOut.commitText)'")

        // 8. Verify top-edge Spacebar tap during short-code composing (`validNextMask != all`) is NOT stolen by Row 2!
        bridge.clearComposition()
        let kState = bridge.pushTouch(reportedAscii: UInt8(ascii: "k"), x: Float(kKey.frame.midX), y: Float(kKey.frame.midY), isNormalized: false, timestampMs: 3000)
        let topEdgeSpaceTap = CGPoint(x: spaceKey.frame.midX, y: spaceKey.frame.minY - 4.0)
        let spaceHit = IOSKeyboardLayoutEngine.hitTest(point: topEdgeSpaceTap, in: snap, validNextMask: kState.validNextMask)
        assert(spaceHit?.kind == .space, "Expected top-edge Spacebar tap during short-code composing to hit Space, got \(String(describing: spaceHit?.kind))")

        // 9. Verify Sacred Keycap Core: light off-center tap >= 3.0pt inside a non-continuation key ('i' after 'trw')
        //    is NEVER hijacked by adjacent valid key ('u'), while < 3.0pt bevel slip still snaps!
        let interiorInsideI = CGPoint(x: iKey.frame.minX + 3.5, y: uKey.frame.midY)
        let sacredHit = IOSKeyboardLayoutEngine.hitTest(point: interiorInsideI, in: snap, validNextMask: afterTrw.validNextMask)
        assert(sacredHit?.kind == .letter(UInt8(ascii: "i")), "Expected sacred keycap core to preserve tap inside 'i', got \(String(describing: sacredHit?.kind))")

        // 10. Verify portrait 220pt canvas (`273pt - 53pt` ribbon) matches native 45pt keyH + 11pt rowGap + 7.0pt catch margin,
        //     and outer-margin corner tap beside 'z' never mutates to 'a' in Rust `push_touch_letter`!
        let snap220 = layout.computeLayout(in: CGSize(width: 440, height: 220))
        let space220 = snap220.keys.first(where: { $0.kind == .space })!
        let q220 = snap220.keys.first(where: { $0.kind == .letter(UInt8(ascii: "q")) })!
        assert(abs(q220.frame.height - 45.0) < 0.01, "Expected 45pt key height, got \(q220.frame.height)")
        assert(220.0 - space220.frame.maxY >= 6.5, "Expected >= 6.5pt bottom catch margin below Spacebar, got \(220.0 - space220.frame.maxY)")
        let bottomRimSpaceTap = CGPoint(x: space220.frame.midX, y: 219.5)
        let bottomSpaceHit = IOSKeyboardLayoutEngine.hitTest(point: bottomRimSpaceTap, in: snap220, validNextMask: kState.validNextMask)
        assert(bottomSpaceHit?.kind == .space, "Expected bottom-rim tap at y=219.5 to hit Spacebar")

        bridge.clearComposition()
        bridge.setKeyLayout(
            centers52: snap220.centers52,
            originX: snap220.originX,
            originY: snap220.originY,
            pitchX: snap220.pitchX,
            pitchY: snap220.pitchY
        )
        let z220 = snap220.keys.first(where: { $0.kind == .letter(UInt8(ascii: "z")) })!
        let zCorner = CGPoint(x: z220.frame.minX - 9.0, y: z220.frame.minY + 3.0)
        let zHit = IOSKeyboardLayoutEngine.hitTest(point: zCorner, in: snap220)
        assert(zHit?.kind == .letter(UInt8(ascii: "z")), "Expected gutter tap beside 'z' to hit 'z'")
        let zOut = bridge.pushTouch(reportedAscii: UInt8(ascii: "z"), x: Float(zCorner.x), y: Float(zCorner.y), isNormalized: false, timestampMs: 4000)
        assert(zOut.preedit == "z", "Expected Rust view-space touch to preserve UI hit-tested 'z', got '\(zOut.preedit)'")

        print("✓ All iOS 26 native grid, lowercase/shift, trackpad, ergonomic Y-bias & dynamic next-key tests passed!")
    }
}
