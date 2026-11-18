import XCTest
import UIKit

private final class ReplayTouch: UITouch {
    var point: CGPoint = .zero
    override func location(in view: UIView?) -> CGPoint { point }
}

final class OverlapReplay: XCTestCase {
    @MainActor
    func testTwoThumbRolloverAndLiftOutside() {
        let canvas = IOSKeyCanvasView()
        let snapshot = IOSKeyboardLayoutEngine().computeLayout(in: CGSize(width: 440, height: 219))
        canvas.updateSnapshot(snapshot)
        var typed = ""
        canvas.onLetterPress = { key, _ in typed += key.primaryLabel }
        canvas.onKeyTouchUp = { key, _ in typed += key.primaryLabel }
        let expected = String(repeating: "trwu", count: 8)
        var previous: ReplayTouch?
        for letter in expected {
            let key = snapshot.keys.first { $0.primaryLabel == String(letter) }!
            let touch = ReplayTouch()
            touch.point = CGPoint(x: key.frame.midX, y: key.frame.midY)
            canvas.touchesBegan([touch], with: nil)
            if let previous {
                previous.point = CGPoint(x: -20, y: -20)
                canvas.touchesEnded([previous], with: nil)
            }
            previous = touch
        }
        previous!.point = CGPoint(x: -20, y: -20)
        canvas.touchesEnded([previous!], with: nil)
        XCTAssertEqual(typed, expected)
    }
}
