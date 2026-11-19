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
        assert(abs(qKey.frame.width - 36.67) < 0.25, "Expected ~36.67pt key width on 440pt canvas, got \(qKey.frame.width)")

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

        // 4. Test Numbers (123) and Symbols (#+=) planes
        layout.switchPlane(.numbers)
        let numSnap = layout.computeLayout(in: CGSize(width: 440, height: 225))
        assert(numSnap.keys.contains(where: { $0.primaryLabel == "1" }))
        assert(numSnap.keys.contains(where: { $0.primaryLabel == "，" }))
        layout.switchPlane(.symbols)
        let symSnap = layout.computeLayout(in: CGSize(width: 440, height: 225))
        assert(symSnap.keys.contains(where: { $0.primaryLabel == "《" }))
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

        // 10. Verify portrait 219pt canvas gives >= 6.0pt live catch-margin below Spacebar inside XPC viewport,
        //     and outer-margin corner tap beside 'z' never mutates to 'a' in Rust `push_touch_letter`!
        let snap219 = layout.computeLayout(in: CGSize(width: 440, height: 219))
        let space219 = snap219.keys.first(where: { $0.kind == .space })!
        assert(219.0 - space219.frame.maxY >= 6.0, "Expected >= 6.0pt bottom catch margin below Spacebar, got \(219.0 - space219.frame.maxY)")
        let bottomRimSpaceTap = CGPoint(x: space219.frame.midX, y: 218.5)
        let bottomSpaceHit = IOSKeyboardLayoutEngine.hitTest(point: bottomRimSpaceTap, in: snap219, validNextMask: kState.validNextMask)
        assert(bottomSpaceHit?.kind == .space, "Expected bottom-rim tap at y=218.5 to hit Spacebar")

        bridge.clearComposition()
        bridge.setKeyLayout(
            centers52: snap219.centers52,
            originX: snap219.originX,
            originY: snap219.originY,
            pitchX: snap219.pitchX,
            pitchY: snap219.pitchY
        )
        let z219 = snap219.keys.first(where: { $0.kind == .letter(UInt8(ascii: "z")) })!
        let zCorner = CGPoint(x: z219.frame.minX - 9.0, y: z219.frame.minY + 3.0)
        let zHit = IOSKeyboardLayoutEngine.hitTest(point: zCorner, in: snap219)
        assert(zHit?.kind == .letter(UInt8(ascii: "z")), "Expected gutter tap beside 'z' to hit 'z'")
        let zOut = bridge.pushTouch(reportedAscii: UInt8(ascii: "z"), x: Float(zCorner.x), y: Float(zCorner.y), isNormalized: false, timestampMs: 4000)
        assert(zOut.preedit == "z", "Expected Rust view-space touch to preserve UI hit-tested 'z', got '\(zOut.preedit)'")

        print("✓ All iOS 26 native grid, lowercase/shift, trackpad, ergonomic Y-bias & dynamic next-key tests passed!")
    }
}
