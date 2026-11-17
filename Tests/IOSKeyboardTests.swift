import CoreGraphics
import Foundation

@main
struct IOSKeyboardTests {
    @MainActor
    static func main() {
        // 1. Test iOS 4-row layout geometry across Portrait (393x216) and Landscape (852x160)
        var layout = IOSKeyboardLayoutEngine()
        layout.returnRole = .send
        let portrait = layout.computeLayout(in: CGSize(width: 393, height: 216))
        assert(portrait.keys.count == 33, "Expected 26 letters + Shift + Del + 5 bottom keys = 33, got \(portrait.keys.count)")
        assert(portrait.pitchX > 38 && portrait.pitchX < 40)

        let returnSpec = portrait.keys.first(where: { $0.kind == .returnKey })!
        assert(returnSpec.primaryLabel == "发送" && returnSpec.isBlueAccent)

        // 2. Test Voronoi gutter hit-testing (no dead zones between T and Y!)
        let tSpec = portrait.keys.first(where: { $0.kind == .letter(UInt8(ascii: "t")) })!
        let ySpec = portrait.keys.first(where: { $0.kind == .letter(UInt8(ascii: "y")) })!
        let gutterMid = CGPoint(x: (tSpec.frame.maxX + ySpec.frame.minX) * 0.5 - 0.5, y: tSpec.frame.midY)
        let gutterHit = IOSKeyboardLayoutEngine.hitTest(point: gutterMid, in: portrait)
        assert(gutterHit?.kind == .letter(UInt8(ascii: "t")), "Expected gutter point slightly closer to T to resolve to T")

        // 3. Test Shift -> UpperOnce -> Double-tap CapsLock -> Lower
        assert(layout.shiftState == .lower)
        layout.tapShift(at: 10.0)
        assert(layout.shiftState == .upperOnce)
        layout.tapShift(at: 10.20) // < 0.34s => CapsLock!
        assert(layout.shiftState == .capsLocked)
        layout.tapShift(at: 11.0)
        assert(layout.shiftState == .lower)

        // 4. Test Numbers (123) and Symbols (#+=) planes
        layout.switchPlane(.numbers)
        let numSnap = layout.computeLayout(in: CGSize(width: 393, height: 216))
        assert(numSnap.keys.contains(where: { $0.primaryLabel == "1" }))
        assert(numSnap.keys.contains(where: { $0.primaryLabel == "，" }))
        layout.switchPlane(.symbols)
        let symSnap = layout.computeLayout(in: CGSize(width: 393, height: 216))
        assert(symSnap.keys.contains(where: { $0.primaryLabel == "《" }))
        layout.switchPlane(.letters)

        // 5. Test Spacebar Trackpad Cursor Accumulator
        var trackpad = SpaceTrackpadAccumulator()
        trackpad.begin(at: 180.0)
        assert(trackpad.update(x: 185.0) == 0)
        assert(trackpad.update(x: 200.0) == 2)  // +20pt => +2 chars
        assert(trackpad.update(x: 189.0) == -1) // -10pt from new anchor => -1 char
        trackpad.end()
        assert(!trackpad.isActive)

        // 6. Test end-to-end iOS view coordinates -> Rust wubi-core set_key_layout + push_touch_json + expanded 60 candidates + touchCalibrations!
        let dictsURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Dicts", isDirectory: true)
        let bridge = WubiBridge(customDictsDir: dictsURL, inMemoryOnly: true)
        bridge.setKeyLayout(
            centers52: portrait.centers52,
            originX: portrait.originX,
            originY: portrait.originY,
            pitchX: portrait.pitchX,
            pitchY: portrait.pitchY
        )

        // Simulate iPhone thumb tapping right border of T (slipping slightly into Y!), then R, W, U -> "我们"!
        let rSpec = portrait.keys.first(where: { $0.kind == .letter(UInt8(ascii: "r")) })!
        let wSpec = portrait.keys.first(where: { $0.kind == .letter(UInt8(ascii: "w")) })!
        let uSpec = portrait.keys.first(where: { $0.kind == .letter(UInt8(ascii: "u")) })!

        let borderPoint = CGPoint(x: ySpec.frame.minX + 1.2, y: tSpec.frame.midY + 1.5)
        _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "y"), x: Float(borderPoint.x), y: Float(borderPoint.y), isNormalized: false, timestampMs: 1000)
        _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "r"), x: Float(rSpec.frame.midX), y: Float(rSpec.frame.midY), isNormalized: false, timestampMs: 1070)
        _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "w"), x: Float(wSpec.frame.midX), y: Float(wSpec.frame.midY), isNormalized: false, timestampMs: 1140)
        let out = bridge.pushTouch(reportedAscii: UInt8(ascii: "u"), x: Float(uSpec.frame.midX), y: Float(uSpec.frame.midY), isNormalized: false, timestampMs: 1210)
        assert(out.candidates.first?.text == "我们", "Expected iPhone view-space touch slip rescue '我们'")

        // Select via `selectAbsCandidate` (used by iOS Expanded Candidate Grid) and verify touch calibration profile JSON!
        let committed = bridge.selectAbsCandidate(absIndex: 0, timestampMs: 1300)
        assert(committed.commitText == "我们")
        assert(bridge.touchCalibrations.count == 26)
        let tCal = bridge.touchCalibrations.first(where: { $0.key == "t" })!
        assert(tCal.samples == 1 && tCal.dx > 0.02, "Expected key 't' to learn rightward thumb drift, got \(tCal)")

        // Test `allCandidates` expansion for `zguo`
        for ch in "zguo".unicodeScalars {
            _ = bridge.handleKey(keyCode: 0, scalar: ch.value, hasCmdOrCtrl: false, timestampMs: 2000)
        }
        let expanded = bridge.allCandidates(maxCount: 40)
        assert(expanded.count >= 8, "Expected multiple expanded candidates for zguo, got \(expanded.count)")

        print("✓ All iOS Virtual Keyboard layout, trackpad, expanded grid & view-space touch calibration tests passed!")
    }
}
