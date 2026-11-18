import Foundation

@main
struct SwiftBridgeTests {
    @MainActor
    static func main() {
        let dictsURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Dicts", isDirectory: true)
        let bridge = WubiBridge(customDictsDir: dictsURL, inMemoryOnly: true)

        // 1. Verify 86 / 98 / 06 schema switching & dynamic phrase re-encoding
        assert(bridge.state.schemaId == 86)
        let code86 = bridge.addUserPhrase("棱五笔", persist: false)
        assert(!code86.isEmpty, "Expected 86 phrase code for 棱五笔")

        bridge.switchSchema(98, persist: false)
        assert(bridge.state.schemaId == 98)
        assert(bridge.userPhrases.contains(where: { $0.text == "棱五笔" && !$0.code.isEmpty }))

        bridge.switchSchema(6, persist: false)
        assert(bridge.state.schemaId == 6)

        // Switch back to 86 for typing & touch tests
        bridge.switchSchema(86, persist: false)

        // 2. Verify 4-code unique auto-commit ("我们" = trwu)
        for ch in "trw".unicodeScalars {
            let s = bridge.handleKey(keyCode: 0, scalar: ch.value, hasCmdOrCtrl: false, timestampMs: 100)
            assert(s.commitText.isEmpty)
        }
        let s4 = bridge.handleKey(keyCode: 0, scalar: UnicodeScalar("u").value, hasCmdOrCtrl: false, timestampMs: 120)
        assert(s4.commitText == "我们", "Expected auto-commit 我们, got \(s4.commitText)")

        // 3. Verify continuous touch boundary Bayesian typo rescue (`yrwu` near T/Y border -> "我们")
        _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "y"), x: 4.54, y: 0.03, isNormalized: true, timestampMs: 200)
        _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "r"), x: 3.00, y: 0.00, isNormalized: true, timestampMs: 260)
        _ = bridge.pushTouch(reportedAscii: UInt8(ascii: "w"), x: 1.00, y: 0.00, isNormalized: true, timestampMs: 320)
        let touchOut = bridge.pushTouch(reportedAscii: UInt8(ascii: "u"), x: 6.00, y: 0.00, isNormalized: true, timestampMs: 380)
        assert(
            touchOut.candidates.first?.text == "我们",
            "Expected Bayesian touch rescue #1 == 我们, got \(String(describing: touchOut.candidates.first?.text))"
        )
        let confirm = bridge.handleKey(keyCode: 0x31, scalar: 32, hasCmdOrCtrl: false, timestampMs: 420)
        assert(confirm.commitText == "我们")
        assert(confirm.calibratedKeyCount >= 1, "Expected online touch adaptation to record calibrated keys")

        // 4. Verify TOML round-trip
        var prefs = bridge.prefs
        prefs.strictShortcode = true
        prefs.promoteThreshold = 0.86
        let decoded = WubiPreferences.fromTOML(prefs.toTOML())
        assert(decoded.strictShortcode == true)
        assert(abs(decoded.promoteThreshold - 0.86) < 0.005)

        // 5. Verify pure AppKit NativeCandidateContentView NEVER wraps lines even across narrow->wide transitions
        let candidateView = NativeCandidateContentView(frame: NSRect(x: 0, y: 0, width: 90, height: 30))
        candidateView.maxAllowedWidth = 800
        let narrowState = WubiActionState(
            consumed: true, bell: false, asciiMode: false, schemaId: 86, page: 0, totalPages: 1, vertical: false,
            schemaName: "86版五笔", commitText: "", preedit: "g", notice: "", userPhraseCount: 0, calibratedKeyCount: 0,
            candidates: [WubiCandidateItem(index: 1, text: "一", comment: "", badge: 0, confidence: 1, isExact: true)]
        )
        candidateView.state = narrowState
        let sz1 = candidateView.computeFittingSize()
        assert(sz1.height == 30.0, "Expected exact 30pt single-line bar height, got \(sz1.height)")

        let wideMultiPhraseState = WubiActionState(
            consumed: true, bell: false, asciiMode: false, schemaId: 86, page: 0, totalPages: 3, vertical: false,
            schemaName: "86版五笔", commitText: "", preedit: "khk", notice: "", userPhraseCount: 0, calibratedKeyCount: 0,
            candidates: [
                WubiCandidateItem(index: 1, text: "中华人民共和国", comment: "⚡k", badge: 1, confidence: 1, isExact: true),
                WubiCandidateItem(index: 2, text: "一心一意", comment: "", badge: 0, confidence: 1, isExact: true),
                WubiCandidateItem(index: 3, text: "实事求是", comment: "", badge: 0, confidence: 1, isExact: true),
                WubiCandidateItem(index: 4, text: "千方百计", comment: "", badge: 0, confidence: 1, isExact: true),
                WubiCandidateItem(index: 5, text: "自力更生", comment: "", badge: 0, confidence: 1, isExact: true),
            ]
        )
        candidateView.state = wideMultiPhraseState
        let sz2 = candidateView.computeFittingSize()
        assert(sz2.height == 30.0, "Expected strictly single-line 30pt height without wrapping, got \(sz2.height)")
        assert(sz2.width > sz1.width + 200.0, "Expected horizontal candidate bar to expand cleanly on single line")

        print("✓ All Swift <-> Rust C ABI bridge, pure-AppKit non-wrapping candidate bar & Bayesian typo tests passed!")
    }
}
