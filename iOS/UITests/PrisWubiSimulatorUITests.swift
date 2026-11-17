import XCTest

final class PrisWubiSimulatorUITests: XCTestCase {
    @MainActor private static var midPressShot: XCUIScreenshot?

    @MainActor
    func testEnableKeyboardAndLiveWubiTyping() throws {
        // 1. Add 棱五笔 in iOS 26.5 Settings -> 通用 -> 键盘 -> 键盘 -> 添加新键盘
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

        let alreadyAdded = settings.cells.containing(NSPredicate(format: "label CONTAINS '棱五笔'")).firstMatch
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

            let prisRow = settings.staticTexts.containing(NSPredicate(format: "label CONTAINS '棱五笔'")).firstMatch
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

        // Long-press Globe to open the Input Mode picker and select 棱五笔 directly
        globeCoord.press(forDuration: 0.75)
        Thread.sleep(forTimeInterval: 0.6)
        attachHierarchy(of: inputUI, name: "inputui-globe-menu-tree")

        let pickerInInputUI = inputUI.staticTexts.containing(NSPredicate(format: "label CONTAINS '棱五笔'")).firstMatch
        let pickerInApp = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '棱五笔'")).firstMatch
        if pickerInInputUI.waitForExistence(timeout: 1.5) {
            pickerInInputUI.tap()
        } else if pickerInApp.exists && pickerInApp.frame.minY > 500 {
            pickerInApp.tap()
        } else {
            // Dismiss menu if any and cycle Globe until 棱五笔 is active
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

        // 3. Hold `h` key (`dx = 0.598, dy = 0.778`) to capture real live iOS 26 callout bubble!
        Self.midPressShot = nil
        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
            MainActor.assumeIsolated {
                Self.midPressShot = XCUIScreen.main.screenshot()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.598, dy: 0.778)).press(forDuration: 0.75)
        Thread.sleep(forTimeInterval: 0.25)
        if let midShot = Self.midPressShot {
            let att = XCTAttachment(screenshot: midShot)
            att.name = "03-live-priswubi-callout-h"
            att.lifetime = .keepAlways
            add(att)
        } else {
            attachShot(name: "03-live-priswubi-callout-h-fallback")
        }
        // Clear the single `h` composition via backspace (`dx = 0.935, dy = 0.837`)
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
        XCTAssertTrue(val.hasPrefix("我们我们"), "Expected TextField to start with clean '我们我们' (no residual 'h'), got: \(val)")
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
