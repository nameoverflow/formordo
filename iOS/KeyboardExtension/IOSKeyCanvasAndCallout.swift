#if os(iOS)
import UIKit

/// Hardware-accelerated Apple-native iOS 4-row keyboard canvas with continuous Voronoi hit-testing
/// and Spacebar horizontal pan cursor trackpad.
final class IOSKeyCanvasView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }

    var onKeyTouchDown: ((IOSKeySpec) -> Void)?
    var onKeyTouchUp: ((IOSKeySpec, CGPoint) -> Void)?
    var onKeyTouchCancel: (() -> Void)?
    var onTrackpadStateChanged: ((Bool) -> Void)?
    var onTrackpadStep: ((Int) -> Void)?

    private var snapshot: IOSKeyboardLayoutEngine.LayoutSnapshot?
    private var activeKeyId: String?
    private var touchStartPoint: CGPoint = .zero
    private var touchStartedOnSpace: Bool = false
    private var trackpad = SpaceTrackpadAccumulator()
    private var isDark: Bool = false

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

        let regularFill = isDark
            ? UIColor(red: 0.42, green: 0.42, blue: 0.44, alpha: 1.0)
            : UIColor.white
        let systemFill = isDark
            ? UIColor(red: 0.28, green: 0.28, blue: 0.30, alpha: 1.0)
            : UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1.0)
        let activeHighlightFill = isDark
            ? UIColor(white: 0.58, alpha: 1.0)
            : UIColor(red: 0.88, green: 0.90, blue: 0.93, alpha: 1.0)
        let shadowColor = UIColor.black.withAlphaComponent(isDark ? 0.42 : 0.28)
        let labelColor = isDark ? UIColor.white : UIColor.black

        for spec in snap.keys {
            let isPressed = (spec.id == activeKeyId)
            let corner: CGFloat = 5.0

            // 1pt bottom keycap shadow matching iOS system keyboard
            let shadowRect = spec.frame.offsetBy(dx: 0, dy: 1.0)
            let shadowPath = UIBezierPath(roundedRect: shadowRect, cornerRadius: corner)
            shadowColor.setFill()
            shadowPath.fill()

            // Keycap body fill
            let fill: UIColor
            if spec.isBlueAccent {
                fill = isPressed ? UIColor.systemBlue.withAlphaComponent(0.8) : UIColor.systemBlue
            } else if isPressed {
                fill = activeHighlightFill
            } else if spec.isSystemKey {
                fill = systemFill
            } else {
                fill = regularFill
            }
            let bodyPath = UIBezierPath(roundedRect: spec.frame, cornerRadius: corner)
            fill.setFill()
            bodyPath.fill()

            guard !trackpad.isActive else { continue }

            let fgColor = spec.isBlueAccent ? UIColor.white : labelColor
            if let symName = spec.systemSymbol,
               let img = UIImage(
                   systemName: symName,
                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
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
                switch spec.kind {
                case .letter:
                    fontSize = 22.0
                    weight = .regular
                case .symbol(let s):
                    fontSize = s.count > 1 ? 16.0 : 20.0
                    weight = .regular
                case .space:
                    fontSize = 14.5
                    weight = .regular
                case .returnKey:
                    fontSize = 15.0
                    weight = spec.isBlueAccent ? .semibold : .regular
                default:
                    fontSize = 15.0
                    weight = .medium
                }
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: weight),
                    .foregroundColor: fgColor,
                ]
                let ns = spec.primaryLabel as NSString
                let sz = ns.size(withAttributes: attrs)
                let pt = CGPoint(
                    x: spec.frame.midX - sz.width * 0.5,
                    y: spec.frame.midY - sz.height * 0.5
                )
                ns.draw(at: pt, withAttributes: attrs)
            }
        }
        ctx.restoreGState()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let snap = snapshot, let pt = touches.first?.location(in: self) else { return }
        touchStartPoint = pt
        if let hit = IOSKeyboardLayoutEngine.hitTest(point: pt, in: snap) {
            activeKeyId = hit.id
            touchStartedOnSpace = (hit.kind == .space)
            setNeedsDisplay()
            onKeyTouchDown?(hit)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let snap = snapshot, let pt = touches.first?.location(in: self) else { return }

        // Activate Spacebar cursor trackpad when dragging > 10pt horizontally from Spacebar!
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
            // Allow sliding between letter keys before release (updates callout bubble smoothly!)
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
        defer {
            activeKeyId = nil
            touchStartedOnSpace = false
            if trackpad.isActive {
                trackpad.end()
                onTrackpadStateChanged?(false)
            }
            setNeedsDisplay()
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

/// Authentic iOS necked Key Callout bubble connecting enlarged top cap to pressed keycap base.
final class IOSKeyCalloutView: UIView {
    private let glyphLabel = UILabel()
    private var keyWidth: CGFloat = 32
    private var isDark: Bool = false

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 56, height: 102))
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
        let bubbleW = max(keyWidth + 20, 54)
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

        let path = UIBezierPath()
        path.move(to: CGPoint(x: 10, y: 2))
        path.addLine(to: CGPoint(x: w - 10, y: 2))
        path.addQuadCurve(to: CGPoint(x: w - 2, y: 10), controlPoint: CGPoint(x: w - 2, y: 2))
        path.addLine(to: CGPoint(x: w - 2, y: neckY - 12))
        path.addCurve(
            to: CGPoint(x: baseRight, y: neckY + 4),
            controlPoint1: CGPoint(x: w - 2, y: neckY - 3),
            controlPoint2: CGPoint(x: baseRight, y: neckY - 2)
        )
        path.addLine(to: CGPoint(x: baseRight, y: h - 5))
        path.addQuadCurve(to: CGPoint(x: baseRight - 5, y: h), controlPoint: CGPoint(x: baseRight, y: h))
        path.addLine(to: CGPoint(x: baseLeft + 5, y: h))
        path.addQuadCurve(to: CGPoint(x: baseLeft, y: h - 5), controlPoint: CGPoint(x: baseLeft, y: h))
        path.addLine(to: CGPoint(x: baseLeft, y: neckY + 4))
        path.addCurve(
            to: CGPoint(x: 2, y: neckY - 12),
            controlPoint1: CGPoint(x: baseLeft, y: neckY - 2),
            controlPoint2: CGPoint(x: 2, y: neckY - 3)
        )
        path.addLine(to: CGPoint(x: 2, y: 10))
        path.addQuadCurve(to: CGPoint(x: 10, y: 2), controlPoint: CGPoint(x: 2, y: 2))
        path.close()

        let ctx = UIGraphicsGetCurrentContext()
        ctx?.saveGState()
        ctx?.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: UIColor.black.withAlphaComponent(0.28).cgColor)
        let fill = isDark ? UIColor(red: 0.46, green: 0.46, blue: 0.48, alpha: 1.0) : UIColor.white
        fill.setFill()
        path.fill()
        ctx?.restoreGState()

        UIColor.black.withAlphaComponent(0.12).setStroke()
        path.lineWidth = 0.6
        path.stroke()
    }
}
#endif
