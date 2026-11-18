import UIKit
import XCTest

private final class SyntheticFingerTouch: UITouch {
    var mockPoint: CGPoint = .zero
    var mockTimestamp: TimeInterval = 0
    override func location(in view: UIView?) -> CGPoint { mockPoint }
    override var timestamp: TimeInterval { mockTimestamp }
}

final class PrisWubiSimulatorUITests: XCTestCase {
    @MainActor private static var midPressShot: XCUIScreenshot?

    @MainActor
    func testMultiTouchRolloverAndLiftFlickHysteresis() {
        let canvas = IOSKeyCanvasView()
        let snapshot = IOSKeyboardLayoutEngine().computeLayout(in: CGSize(width: 440, height: 219))
        canvas.updateSnapshot(snapshot)

        var committed = ""
        canvas.onKeyTouchUp = { spec, _ in
            committed += spec.primaryLabel
        }

        // 1. Overlapping two-thumb rollover (32 consecutive overlapping taps where finger N+1
        //    presses down BEFORE finger N lifts, and finger N drifts into the candidate ribbon on lift!)
        let sequence = String(repeating: "rtdgthtc", count: 4)
        var clock: TimeInterval = 100.0
        var prevTouch: SyntheticFingerTouch?

        for ch in sequence {
            let key = snapshot.keys.first { $0.primaryLabel == String(ch) }!
            let nextTouch = SyntheticFingerTouch()
            nextTouch.mockPoint = CGPoint(x: key.frame.midX, y: key.frame.midY)
            nextTouch.mockTimestamp = clock
            canvas.touchesBegan([nextTouch], with: nil)

            if let prev = prevTouch {
                // Previous thumb flicks 18pt upward into candidate bar while lifting 22ms later
                clock += 0.022
                prev.mockPoint = CGPoint(x: prev.mockPoint.x + 8.0, y: -18.0)
                prev.mockTimestamp = clock
                canvas.touchesMoved([prev], with: nil)
                canvas.touchesEnded([prev], with: nil)
            }
            prevTouch = nextTouch
            clock += 0.035
        }
        if let last = prevTouch {
            clock += 0.030
            last.mockPoint = CGPoint(x: last.mockPoint.x - 7.0, y: -16.0)
            last.mockTimestamp = clock
            canvas.touchesMoved([last], with: nil)
            canvas.touchesEnded([last], with: nil)
        }
        XCTAssertEqual(committed, sequence, "Zero dropped or reordered keys under overlapping rollover + ribbon lift")

        // 2. Rapid sub-90ms lift-roll across neighbor border (`t` -> rolled 8pt right onto `y` edge on release)
        committed = ""
        let tKey = snapshot.keys.first { $0.primaryLabel == "t" }!
        let yKey = snapshot.keys.first { $0.primaryLabel == "y" }!
        let flick = SyntheticFingerTouch()
        flick.mockPoint = CGPoint(x: tKey.frame.midX, y: tKey.frame.midY)
        flick.mockTimestamp = 200.0
        canvas.touchesBegan([flick], with: nil)

        // 45ms later, thumb rolls 8pt into neighbor `y` while lifting: sticky press-lock keeps `t`!
        flick.mockPoint = CGPoint(x: tKey.frame.maxX + 8.0, y: tKey.frame.midY + 4.0)
        flick.mockTimestamp = 200.045
        canvas.touchesMoved([flick], with: nil)
        canvas.touchesEnded([flick], with: nil)
        XCTAssertEqual(committed, "t", "Sub-90ms thumb lift-roll must stay locked on initial key 't'")

        // 3. Deliberate hold-and-slide (>= 90ms) onto neighbor `y` switches cleanly to `y`!
        committed = ""
        flick.mockPoint = CGPoint(x: tKey.frame.midX, y: tKey.frame.midY)
        flick.mockTimestamp = 205.0
        canvas.touchesBegan([flick], with: nil)
        flick.mockPoint = CGPoint(x: yKey.frame.midX, y: yKey.frame.midY)
        flick.mockTimestamp = 205.16
        canvas.touchesMoved([flick], with: nil)
        canvas.touchesEnded([flick], with: nil)
        XCTAssertEqual(committed, "y", "Deliberate hold-and-slide must switch to neighbor key 'y'")

        // 4. Stationary edge-gate cancellation (`drift <= 14pt`, `dt <= 0.22s`) rescues tap without dropping key,
        //    whereas scroll/dismiss swipe cancellation (`drift > 14pt`) emits zero stray letters!
        committed = ""
        flick.mockPoint = CGPoint(x: tKey.frame.midX, y: tKey.frame.midY)
        flick.mockTimestamp = 210.0
        canvas.touchesBegan([flick], with: nil)
        flick.mockTimestamp = 210.06
        canvas.touchesCancelled([flick], with: nil)
        XCTAssertEqual(committed, "t", "Brief stationary edge-gated cancellation must rescue tap")

        committed = ""
        flick.mockPoint = CGPoint(x: tKey.frame.midX, y: tKey.frame.midY)
        flick.mockTimestamp = 211.0
        canvas.touchesBegan([flick], with: nil)
        flick.mockPoint = CGPoint(x: tKey.frame.midX, y: tKey.frame.midY + 28.0)
        flick.mockTimestamp = 211.09
        canvas.touchesMoved([flick], with: nil)
        canvas.touchesCancelled([flick], with: nil)
        XCTAssertEqual(committed, "", "Interactive scroll/dismiss swipe cancellation must not emit stray letters")

        // 5. Overlapping Backspace rollover ends delete repeat without entering a stray letter
        var releasedKeys: [IOSKeyKind] = []
        canvas.onKeyTouchUp = { spec, _ in
            releasedKeys.append(spec.kind)
            if case .letter = spec.kind {
                committed += spec.primaryLabel
            }
        }
        let backspaceKey = snapshot.keys.first { $0.kind == .backspace }!
        let deleteTouch = SyntheticFingerTouch()
        deleteTouch.mockPoint = CGPoint(x: backspaceKey.frame.midX, y: backspaceKey.frame.midY)
        deleteTouch.mockTimestamp = 212.0
        canvas.touchesBegan([deleteTouch], with: nil)
        deleteTouch.mockPoint = CGPoint(x: tKey.frame.midX, y: tKey.frame.midY)
        deleteTouch.mockTimestamp = 212.1
        canvas.touchesMoved([deleteTouch], with: nil)
        flick.mockPoint = CGPoint(x: tKey.frame.midX, y: tKey.frame.midY)
        flick.mockTimestamp = 212.2
        canvas.touchesBegan([flick], with: nil)
        flick.mockTimestamp = 212.25
        canvas.touchesEnded([deleteTouch, flick], with: nil)
        XCTAssertEqual(releasedKeys, [.backspace, .letter(UInt8(ascii: "t"))])
        XCTAssertEqual(committed, "t")
    }

    @MainActor
    func testEnableKeyboardAndLiveWubiTyping() throws {
        // 1. Add 形序 in iOS 26.5 Settings -> 通用 -> 键盘 -> 键盘 -> 添加新键盘
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()

        let general = settings.cells.containing(.staticText, identifier: "通用").firstMatch
        if general.waitForExistence(timeout: 3) {
            general.tap()
        }
        let kb = settings.cells.containing(.staticText, identifier: "键盘").firstMatch
        if kb.waitForExistence(timeout: 3) {
            kb.tap()
        }
        // Inside General -> Keyboard, tap Keyboards list cell ("键盘")
        let kbsCell = settings.tables.cells.containing(.staticText, identifier: "键盘").firstMatch
        if kbsCell.waitForExistence(timeout: 3) {
            kbsCell.tap()
        }

        let alreadyAdded = settings.cells.containing(NSPredicate(format: "label CONTAINS '形序'")).firstMatch
        if !alreadyAdded.waitForExistence(timeout: 1.5) {
            let addBtn = settings.buttons["AddNewKeyboard"].firstMatch
            let addCell = settings.cells["AddNewKeyboard"].firstMatch
            if addBtn.waitForExistence(timeout: 3) {
                addBtn.tap()
            } else if addCell.exists {
                addCell.tap()
            } else {
                let fallback = settings.staticTexts.containing(NSPredicate(format: "label CONTAINS '添加新键盘'")).firstMatch
                if fallback.exists { fallback.tap() }
            }

            Thread.sleep(forTimeInterval: 0.8)
            attachHierarchy(of: settings, name: "settings-add-keyboard-tree")

            let prisRow = settings.staticTexts.containing(NSPredicate(format: "label CONTAINS '形序'")).firstMatch
            if prisRow.waitForExistence(timeout: 3) {
                prisRow.tap()
                Thread.sleep(forTimeInterval: 0.8)
            }
            let doneBtn = settings.navigationBars.buttons["完成"].firstMatch
            if doneBtn.exists {
                doneBtn.tap()
                Thread.sleep(forTimeInterval: 0.6)
            }
        }
        attachShot(name: "01-settings-keyboards-added")

        // 2. Launch PrisWubiApp and focus the sandbox text field
        let app = XCUIApplication()
        app.launchArguments = ["--autofocus"]
        app.launch()
        Thread.sleep(forTimeInterval: 1.2)

        let inputUI = XCUIApplication(bundleIdentifier: "com.apple.InputUI")
        let globeCoord = app.coordinate(withNormalizedOffset: CGVector(dx: 0.095, dy: 0.955))

        // Long-press Globe to open the Input Mode picker and select 形序 directly
        globeCoord.press(forDuration: 0.75)
        Thread.sleep(forTimeInterval: 0.6)
        attachHierarchy(of: inputUI, name: "inputui-globe-menu-tree")

        let pickerInInputUI = inputUI.staticTexts.containing(NSPredicate(format: "label CONTAINS '形序'")).firstMatch
        let pickerInApp = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '形序'")).firstMatch
        if pickerInInputUI.waitForExistence(timeout: 1.5) {
            pickerInInputUI.tap()
        } else if pickerInApp.exists && pickerInApp.frame.minY > 500 {
            pickerInApp.tap()
        } else {
            // Dismiss menu if any and cycle Globe until 形序 is active
            for _ in 0..<6 {
                globeCoord.tap()
                Thread.sleep(forTimeInterval: 0.7)
                if inputUI.otherElements["PrisWubiRibbon"].exists || app.otherElements["PrisWubiRibbon"].exists {
                    break
                }
            }
        }

        Thread.sleep(forTimeInterval: 1.0)
        attachHierarchy(of: inputUI, name: "inputui-active-keyboard-tree")
        attachShot(name: "02-live-priswubi-idle")

        // Measure exact keyboard position on 440x956pt iPhone 17 Pro Max (`heightConstraint = 263pt`):
        //   Row 0 (q..p): midY ≈ 688pt -> dy = 0.720
        //   Row 1 (a..l): midY ≈ 744pt -> dy = 0.778
        //   Row 2 (z..m): midY ≈ 800pt -> dy = 0.837
        //   Row 3 (space): midY ≈ 856pt -> dy = 0.895

        // 3. Hold the first-row `q` key (`dx = 0.598, dy = 0.778`) to capture real live iOS 26 callout bubble!
        Self.midPressShot = nil
        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
            MainActor.assumeIsolated {
                Self.midPressShot = XCUIScreen.main.screenshot()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.720)).press(forDuration: 0.75)
        Thread.sleep(forTimeInterval: 0.25)
        if let midShot = Self.midPressShot {
            let att = XCTAttachment(screenshot: midShot)
            att.name = "03-live-priswubi-callout-q"
            att.lifetime = .keepAlways
            add(att)
        } else {
            attachShot(name: "03-live-priswubi-callout-q-fallback")
        }
        // Clear the single `q` composition via backspace (`dx = 0.935, dy = 0.837`)
        tapNorm(app, dx: 0.935, dy: 0.837)
        Thread.sleep(forTimeInterval: 0.25)

        // 3a. Hold Row-0 interior `r` key (`dx = 0.352, dy = 0.720`) to verify symmetric Row-0 docked popout!
        Self.midPressShot = nil
        let rTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
            MainActor.assumeIsolated {
                Self.midPressShot = XCUIScreen.main.screenshot()
            }
        }
        RunLoop.main.add(rTimer, forMode: .common)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.352, dy: 0.720)).press(forDuration: 0.75)
        Thread.sleep(forTimeInterval: 0.25)
        if let midShot = Self.midPressShot {
            let att = XCTAttachment(screenshot: midShot)
            att.name = "03a-live-priswubi-callout-r"
            att.lifetime = .keepAlways
            add(att)
        }
        tapNorm(app, dx: 0.935, dy: 0.837)
        Thread.sleep(forTimeInterval: 0.25)

        // 3b. Hold the second-row `h` key (`dx = 0.598, dy = 0.778`) to verify standalone floating squircle parity!
        Self.midPressShot = nil
        let hTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
            MainActor.assumeIsolated {
                Self.midPressShot = XCUIScreen.main.screenshot()
            }
        }
        RunLoop.main.add(hTimer, forMode: .common)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.598, dy: 0.778)).press(forDuration: 0.75)
        Thread.sleep(forTimeInterval: 0.25)
        if let midShot = Self.midPressShot {
            let att = XCTAttachment(screenshot: midShot)
            att.name = "03b-live-priswubi-callout-h"
            att.lifetime = .keepAlways
            add(att)
        }
        tapNorm(app, dx: 0.935, dy: 0.837)
        Thread.sleep(forTimeInterval: 0.25)

        // 4. Tap Wubi 4-code `t-r-w-u` ("我们" auto-commits on 4th keystroke!)
        tapNorm(app, dx: 0.450, dy: 0.720) // t
        Thread.sleep(forTimeInterval: 0.18)
        tapNorm(app, dx: 0.352, dy: 0.720) // r
        Thread.sleep(forTimeInterval: 0.18)
        tapNorm(app, dx: 0.155, dy: 0.720) // w
        Thread.sleep(forTimeInterval: 0.35)
        attachShot(name: "04-live-priswubi-composing-trw")

        tapNorm(app, dx: 0.648, dy: 0.720) // u -> 4-code unique auto-commits "我们"!
        Thread.sleep(forTimeInterval: 0.45)

        // 5. Test boundary-slip typo rescue: tap near the t/y border inside `y` (`dx = 0.515, dy = 0.720`) + `r-w-u`!
        // Pure `yrwu` is an empty Wubi 86 code, so our 2D Gaussian + N-gram decoder rescues `trwu` ("我们") with confidence badge!
        tapNorm(app, dx: 0.515, dy: 0.720) // slip onto left side of `y` (near `t`)
        Thread.sleep(forTimeInterval: 0.18)
        tapNorm(app, dx: 0.352, dy: 0.720) // r
        Thread.sleep(forTimeInterval: 0.18)
        tapNorm(app, dx: 0.155, dy: 0.720) // w
        Thread.sleep(forTimeInterval: 0.18)
        tapNorm(app, dx: 0.648, dy: 0.720) // u -> rescued candidate stays on ribbon (no blind 4-code auto-commit!)
        Thread.sleep(forTimeInterval: 0.45)
        attachShot(name: "05-live-priswubi-typo-rescue-yrwu")

        // Commit rescued candidate via Spacebar (`dx = 0.500, dy = 0.895`)
        tapNorm(app, dx: 0.500, dy: 0.895)
        Thread.sleep(forTimeInterval: 0.35)

        // A fifth key commits the previous word and begins the next composition.
        // This is the exact boundary that left a literal 't' in the phone recording.
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        for ch in "rtdgthtcs" {
            for (row, letters) in rows.enumerated() {
                guard let index = Array(letters).firstIndex(of: ch) else { continue }
                let x = [0.05, 0.10, 0.20][row] + Double(index) * 0.10
                tapNorm(app, dx: x, dy: [0.720, 0.778, 0.837][row])
            }
        }
        let field = app.textFields.firstMatch
        XCTAssertEqual(field.value as? String, "我们我们手感怎么s")
        attachShot(name: "continuous-input")
        tapNorm(app, dx: 0.935, dy: 0.837) // discard pending s
        XCTAssertEqual(field.value as? String, "我们我们手感怎么")

        // 6. Tap `k-h-k` (`中 ⚡k`) so Simulator ends with live Wubi candidates & short-code hint on screen
        tapNorm(app, dx: 0.795, dy: 0.778) // k
        Thread.sleep(forTimeInterval: 0.18)
        tapNorm(app, dx: 0.598, dy: 0.778) // h
        Thread.sleep(forTimeInterval: 0.18)
        tapNorm(app, dx: 0.795, dy: 0.778) // k
        Thread.sleep(forTimeInterval: 0.45)
        attachShot(name: "06-live-priswubi-khk")

        let tf = app.textFields.firstMatch
        let val = (tf.value as? String) ?? ""
        XCTAssertEqual(val, "我们我们手感怎么khk")

        // Change an option in the host, then open the keyboard in a fresh session.
        app.launchArguments = []
        app.launch()
        app.buttons["输入设置"].tap()
        let autoCommit = app.switches["四码唯一自动上屏"]
        XCTAssertEqual(autoCommit.value as? String, "1")
        autoCommit.tap()
        attachShot(name: "host-settings")
        defer {
            app.launchArguments = []
            app.launch()
            app.buttons["输入设置"].tap()
            if autoCommit.value as? String == "0" { autoCommit.tap() }
        }
        app.launchArguments = ["--autofocus"]
        app.launch()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        for x in [0.450, 0.352, 0.155, 0.648] { tapNorm(app, dx: x, dy: 0.720) }
        XCTAssertNotEqual(app.textFields.firstMatch.value as? String, "我们")
        tapNorm(app, dx: 0.500, dy: 0.895)
        XCTAssertEqual(app.textFields.firstMatch.value as? String, "我们")

        let space = app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.895))
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.478, dy: 0.895))
        space.press(forDuration: 0.6, thenDragTo: left)
        tapNorm(app, dx: 0.06, dy: 0.895) // 123
        tapNorm(app, dx: 0.21, dy: 0.837) // full stop
        XCTAssertEqual(app.textFields.firstMatch.value as? String, "我。们")
        tapNorm(app, dx: 0.450, dy: 0.720) // back on letters
        XCTAssertEqual(app.textFields.firstMatch.value as? String, "我。t们")
        tapNorm(app, dx: 0.935, dy: 0.837) // erase marked t
        let numbers = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.895))
        let five = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.720))
        numbers.press(forDuration: 0.4, thenDragTo: five)
        XCTAssertEqual(app.textFields.firstMatch.value as? String, "我。5们")
        five.tap()
        XCTAssertEqual(app.textFields.firstMatch.value as? String, "我。5t们")

    }

    @MainActor
    private func tapNorm(_ app: XCUIApplication, dx: CGFloat, dy: CGFloat) {
        app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).tap()
    }

    @MainActor
    private func attachShot(name: String) {
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    @MainActor
    private func attachHierarchy(of app: XCUIApplication, name: String) {
        let att = XCTAttachment(string: app.debugDescription)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }
}
