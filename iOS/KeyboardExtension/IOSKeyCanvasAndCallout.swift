#if os(iOS)
import UIKit

/// Hardware-accelerated iOS 26 ("Liquid Glass") native 4-row keyboard canvas:
/// - Uniform white (`#FFFFFF`) 8.5pt continuous-corner keycaps in Light mode, uniform `#47474B` in Dark mode
/// - Lowercase SF Pro Regular letter legends, crisp `1.6pt` stroke SF Symbols (`shift`, `delete.backward`, `return.left`)
/// - Clean Spacebar with subtle bottom-right `"五"` subscript
/// - Continuous Voronoi hit-testing & horizontal Spacebar cursor trackpad
final class IOSKeyCanvasView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }

    var onKeyTouchDown: ((IOSKeySpec) -> Void)?
    var onKeyTouchUp: ((IOSKeySpec, CGPoint) -> Void)?
    var onKeyTouchCancel: (() -> Void)?
    var onModeKeyLongPress: (() -> Void)?
    var onTrackpadStateChanged: ((Bool) -> Void)?
    var onTrackpadStep: ((Int) -> Void)?

    private var snapshot: IOSKeyboardLayoutEngine.LayoutSnapshot?
    private var activeKeyId: String?
    private var touchStartPoint: CGPoint = .zero
    private var touchStartedOnSpace: Bool = false
    private var trackpad = SpaceTrackpadAccumulator()
    private var isDark: Bool = false
    private var modeLongPressTimer: Timer?
    private var didTriggerLongPress: Bool = false

    init() {
        super.init(frame: .zero, inputViewStyle: .keyboard)
        isMultipleTouchEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(dark: Bool) {
        isDark = dark
        setNeedsDisplay()
    }

    func updateSnapshot(_ snap: IOSKeyboardLayoutEngine.LayoutSnapshot) {
        self.snapshot = snap
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let snap = snapshot, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()

        let keyFill = isDark
            ? UIColor(red: 0.28, green: 0.28, blue: 0.30, alpha: 1.0)
            : UIColor.white
        let pressedFill = isDark
            ? UIColor(red: 0.38, green: 0.38, blue: 0.41, alpha: 1.0)
            : UIColor(red: 0.91, green: 0.92, blue: 0.94, alpha: 1.0)
        let labelColor = isDark ? UIColor.white : UIColor.black
        let subscriptColor = isDark
            ? UIColor(white: 1.0, alpha: 0.40)
            : UIColor(red: 0.64, green: 0.65, blue: 0.67, alpha: 1.0)
        let corner = IOSKeyboardLayoutEngine.keyCornerRadius

        for spec in snap.keys {
            let isPressed = (spec.id == activeKeyId)
            let fill: UIColor
            if spec.isBlueAccent {
                fill = isPressed ? UIColor.systemBlue.withAlphaComponent(0.82) : UIColor.systemBlue
            } else if isPressed {
                fill = pressedFill
            } else {
                fill = keyFill
            }

            let path = UIBezierPath(roundedRect: spec.frame, cornerRadius: corner)
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: 0.5),
                blur: 0.6,
                color: UIColor.black.withAlphaComponent(isDark ? 0.24 : 0.04).cgColor
            )
            fill.setFill()
            path.fill()
            ctx.restoreGState()

            guard !trackpad.isActive else { continue }

            let fgColor = spec.isBlueAccent ? UIColor.white : labelColor

            if let symName = spec.systemSymbol,
               let img = UIImage(
                   systemName: symName,
                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 18.5, weight: .regular)
               )?.withTintColor(fgColor, renderingMode: .alwaysOriginal) {
                let imgRect = CGRect(
                    x: spec.frame.midX - img.size.width * 0.5,
                    y: spec.frame.midY - img.size.height * 0.5,
                    width: img.size.width,
                    height: img.size.height
                )
                img.draw(in: imgRect)
            } else if !spec.primaryLabel.isEmpty {
                let fontSize: CGFloat
                let weight: UIFont.Weight
                let yNudge: CGFloat
                switch spec.kind {
                case .letter:
                    fontSize = 23.5
                    weight = .regular
                    yNudge = -1.2
                case .symbol(let s):
                    fontSize = s.count > 1 ? 16.5 : 21.0
                    weight = .regular
                    yNudge = -0.5
                case .returnKey:
                    fontSize = 15.5
                    weight = spec.isBlueAccent ? .semibold : .regular
                    yNudge = 0
                default:
                    fontSize = 16.5
                    weight = .regular
                    yNudge = 0
                }
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: weight),
                    .foregroundColor: fgColor,
                ]
                let ns = spec.primaryLabel as NSString
                let sz = ns.size(withAttributes: attrs)
                let pt = CGPoint(
                    x: spec.frame.midX - sz.width * 0.5,
                    y: spec.frame.midY - sz.height * 0.5 + yNudge
                )
                ns.draw(at: pt, withAttributes: attrs)
            }

            // Subtle bottom-right corner tag (`"五"` / `"EN"`) on Spacebar matching iOS 26 native Wubi!
            if let sub = spec.cornerSubscript, !sub.isEmpty {
                let subAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 11.5, weight: .regular),
                    .foregroundColor: subscriptColor,
                ]
                let ns = sub as NSString
                let sz = ns.size(withAttributes: subAttrs)
                ns.draw(
                    at: CGPoint(x: spec.frame.maxX - sz.width - 7.5, y: spec.frame.maxY - sz.height - 4.5),
                    withAttributes: subAttrs
                )
            }
        }
        ctx.restoreGState()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let snap = snapshot, let pt = touches.first?.location(in: self) else { return }
        touchStartPoint = pt
        didTriggerLongPress = false
        modeLongPressTimer?.invalidate()

        if let hit = IOSKeyboardLayoutEngine.hitTest(point: pt, in: snap) {
            activeKeyId = hit.id
            touchStartedOnSpace = (hit.kind == .space)
            setNeedsDisplay()
            onKeyTouchDown?(hit)

            if hit.kind == .modeToggle || hit.kind == .space {
                if hit.kind == .modeToggle {
                    modeLongPressTimer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self] _ in
                        Task { @MainActor in
                            guard let self else { return }
                            self.didTriggerLongPress = true
                            self.onModeKeyLongPress?()
                        }
                    }
                }
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let snap = snapshot, let pt = touches.first?.location(in: self) else { return }
        if hypot(pt.x - touchStartPoint.x, pt.y - touchStartPoint.y) > 8 {
            modeLongPressTimer?.invalidate()
        }

        if touchStartedOnSpace {
            if !trackpad.isActive && abs(pt.x - touchStartPoint.x) >= 10.0 {
                trackpad.begin(at: pt.x)
                activeKeyId = nil
                onTrackpadStateChanged?(true)
                setNeedsDisplay()
            }
            if trackpad.isActive {
                let step = trackpad.update(x: pt.x)
                if step != 0 {
                    onTrackpadStep?(step)
                }
                return
            }
        }

        if let hit = IOSKeyboardLayoutEngine.hitTest(point: pt, in: snap), hit.id != activeKeyId {
            activeKeyId = hit.id
            setNeedsDisplay()
            if case .letter = hit.kind {
                onKeyTouchDown?(hit)
            } else {
                onKeyTouchCancel?()
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        modeLongPressTimer?.invalidate()
        defer {
            activeKeyId = nil
            touchStartedOnSpace = false
            if trackpad.isActive {
                trackpad.end()
                onTrackpadStateChanged?(false)
            }
            setNeedsDisplay()
        }
        if didTriggerLongPress {
            return
        }
        guard !trackpad.isActive,
              let snap = snapshot,
              let pt = touches.first?.location(in: self),
              let hit = IOSKeyboardLayoutEngine.hitTest(point: pt, in: snap) else {
            onKeyTouchCancel?()
            return
        }
        onKeyTouchUp?(hit, pt)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        modeLongPressTimer?.invalidate()
        activeKeyId = nil
        touchStartedOnSpace = false
        if trackpad.isActive {
            trackpad.end()
            onTrackpadStateChanged?(false)
        }
        onKeyTouchCancel?()
        setNeedsDisplay()
    }
}

/// Authentic iOS 26 soft-squircle necked Key Callout bubble.
final class IOSKeyCalloutView: UIView {
    private let glyphLabel = UILabel()
    private var keyWidth: CGFloat = 36
    private var isDark: Bool = false

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 58, height: 106))
        isOpaque = false
        isUserInteractionEnabled = false
        glyphLabel.font = .systemFont(ofSize: 32, weight: .regular)
        glyphLabel.textAlignment = .center
        addSubview(glyphLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(label: String, over keyFrameInSuperview: CGRect, dark: Bool) {
        isDark = dark
        keyWidth = keyFrameInSuperview.width
        let bubbleW = max(keyWidth + 18, 54)
        let totalH = keyFrameInSuperview.height + 56
        frame = CGRect(
            x: keyFrameInSuperview.midX - bubbleW * 0.5,
            y: keyFrameInSuperview.maxY - totalH,
            width: bubbleW,
            height: totalH
        )
        glyphLabel.text = label
        glyphLabel.textColor = dark ? .white : .black
        glyphLabel.frame = CGRect(x: 0, y: 4, width: bubbleW, height: 50)
        isHidden = false
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        let w = bounds.width
        let h = bounds.height
        let baseW = min(w - 4, keyWidth)
        let baseLeft = (w - baseW) * 0.5
        let baseRight = baseLeft + baseW
        let neckY: CGFloat = 54
        let rTop: CGFloat = 12.0
        let rBot: CGFloat = 8.5

        let path = UIBezierPath()
        path.move(to: CGPoint(x: rTop + 2, y: 2))
        path.addLine(to: CGPoint(x: w - rTop - 2, y: 2))
        path.addQuadCurve(to: CGPoint(x: w - 2, y: rTop + 2), controlPoint: CGPoint(x: w - 2, y: 2))
        path.addLine(to: CGPoint(x: w - 2, y: neckY - 12))
        path.addCurve(
            to: CGPoint(x: baseRight, y: neckY + 4),
            controlPoint1: CGPoint(x: w - 2, y: neckY - 3),
            controlPoint2: CGPoint(x: baseRight, y: neckY - 2)
        )
        path.addLine(to: CGPoint(x: baseRight, y: h - rBot))
        path.addQuadCurve(to: CGPoint(x: baseRight - rBot, y: h), controlPoint: CGPoint(x: baseRight, y: h))
        path.addLine(to: CGPoint(x: baseLeft + rBot, y: h))
        path.addQuadCurve(to: CGPoint(x: baseLeft, y: h - rBot), controlPoint: CGPoint(x: baseLeft, y: h))
        path.addLine(to: CGPoint(x: baseLeft, y: neckY + 4))
        path.addCurve(
            to: CGPoint(x: 2, y: neckY - 12),
            controlPoint1: CGPoint(x: baseLeft, y: neckY - 2),
            controlPoint2: CGPoint(x: 2, y: neckY - 3)
        )
        path.addLine(to: CGPoint(x: 2, y: rTop + 2))
        path.addQuadCurve(to: CGPoint(x: rTop + 2, y: 2), controlPoint: CGPoint(x: 2, y: 2))
        path.close()

        let ctx = UIGraphicsGetCurrentContext()
        ctx?.saveGState()
        ctx?.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: UIColor.black.withAlphaComponent(0.16).cgColor)
        let fill = isDark ? UIColor(red: 0.34, green: 0.34, blue: 0.37, alpha: 1.0) : UIColor.white
        fill.setFill()
        path.fill()
        ctx?.restoreGState()

        UIColor.black.withAlphaComponent(0.08).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}
#endif
