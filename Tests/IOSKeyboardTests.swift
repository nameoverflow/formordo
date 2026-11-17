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

        print("✓ All iOS 26 native grid, lowercase/shift, trackpad & Bayesian touch rescue tests passed!")
    }
}
