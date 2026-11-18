#if os(iOS)
import UIKit

/// Hardware-accelerated iOS 26 ("Liquid Glass") native 4-row keyboard canvas.
final class IOSKeyCanvasView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }

    var onKeyTouchDown: ((IOSKeySpec) -> Void)?
    var onKeyTouchUp: ((IOSKeySpec, CGPoint) -> Void)?
    var onKeyTouchCancel: (() -> Void)?
    var onTrackpadStateChanged: ((Bool) -> Void)?
    var onTrackpadStep: ((Int) -> Void)?

    private var snapshot: IOSKeyboardLayoutEngine.LayoutSnapshot?
    private var activeTouch: UITouch?
    private var activeKeyId: String?
    private var touchStartPoint: CGPoint = .zero
    private var touchStartedOnSpace: Bool = false
    private var trackpad = SpaceTrackpadAccumulator()
    private var isDark: Bool = false

    init() {
        super.init(frame: .zero, inputViewStyle: .keyboard)
        isMultipleTouchEnabled = true
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
        // Depressed keycap fill matching IMG_2628 (`h` slot subtly recessed relative to surrounding white keys)
        let pressedFill = isDark
            ? UIColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 1.0)
            : UIColor(red: 219.0 / 255.0, green: 220.0 / 255.0, blue: 224.0 / 255.0, alpha: 1.0)
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
            if !isPressed {
                ctx.setShadow(
                    offset: CGSize(width: 0, height: 0.5),
                    blur: 0.6,
                    color: UIColor.black.withAlphaComponent(isDark ? 0.24 : 0.04).cgColor
                )
            }
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
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            if let previous = activeTouch { finishTouch(previous) }
            let point = touch.location(in: self)
            guard let snapshot, let hit = IOSKeyboardLayoutEngine.hitTest(point: point, in: snapshot) else { continue }
            activeTouch = touch
            touchStartPoint = point
            activeKeyId = hit.id
            touchStartedOnSpace = hit.kind == .space
            setNeedsDisplay()
            onKeyTouchDown?(hit)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch), let snap = snapshot else { return }
        let pt = activeTouch.location(in: self)
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
            onKeyTouchCancel?()
            activeKeyId = hit.id
            setNeedsDisplay()
            if case .letter = hit.kind {
                onKeyTouchDown?(hit)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        finishTouch(activeTouch)
    }

    private func finishTouch(_ touch: UITouch) {
        let pt = touch.location(in: self)
        defer {
            activeTouch = nil
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
              let hit = IOSKeyboardLayoutEngine.hitTest(point: pt, in: snap) else {
            onKeyTouchCancel?()
            return
        }
        onKeyTouchUp?(hit, pt)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        self.activeTouch = nil
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

/// Authentic iOS 26 standalone floating squircle Key Callout Bubble (measured 1:1 from IMG_2628):
/// - Zero neck: standalone `61.3 x 65.0pt` continuous-corner (`13.5pt`) floating card
/// - Hovers `3.7pt` above the pressed keycap's top edge while the depressed keycap underneath
///   remains visible at `RGB(230, 231, 232)` with its own glyph intact
/// - `36.5pt` SF Pro Regular glyph optically centered with `19pt` top/bottom margins
final class IOSKeyCalloutView: UIView {
    private let cardView = UIView()
    private let glyphLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 61.33, height: 65.0))
        isOpaque = false
        isUserInteractionEnabled = false
        clipsToBounds = false

        cardView.layer.cornerRadius = 13.5
        cardView.layer.cornerCurve = .continuous
        cardView.layer.shadowColor = UIColor.black.cgColor
        cardView.layer.shadowOffset = CGSize(width: 0, height: 4.0)
        cardView.layer.shadowRadius = 15.0

        glyphLabel.font = .systemFont(ofSize: 36.5, weight: .regular)
        glyphLabel.textAlignment = .center

        addSubview(cardView)
        cardView.addSubview(glyphLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var dismissTimer: Timer?

    func releasePreview() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 0.065, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.isHidden = true }
        }
    }

    func present(label: String, over keyFrameInSuperview: CGRect, dark: Bool) {
        dismissTimer?.invalidate()
        let bubbleW = max(61.33, keyFrameInSuperview.width * 1.67)
        let bubbleH = max(65.0, keyFrameInSuperview.height * 1.44)
        let superW = superview?.bounds.width ?? 440

        let clampedX = min(
            max(4.0, keyFrameInSuperview.midX - bubbleW * 0.5),
            max(4.0, superW - bubbleW - 4.0)
        )
        // Hover 3.67pt above keyFrame.minY; if superview clips top edge (Row 0), clamp softly to 1.5pt
        let rawY = keyFrameInSuperview.minY - 3.67 - bubbleH
        let finalY = max(2, rawY)

        frame = CGRect(x: clampedX, y: finalY, width: bubbleW, height: bubbleH)
        cardView.frame = bounds
        cardView.backgroundColor = dark
            ? UIColor(red: 0.34, green: 0.34, blue: 0.37, alpha: 1.0)
            : UIColor.white
        cardView.layer.shadowOpacity = dark ? 0.38 : 0.13
        cardView.layer.borderWidth = 0.4
        cardView.layer.borderColor = (dark
            ? UIColor.white.withAlphaComponent(0.14)
            : UIColor.black.withAlphaComponent(0.04)).cgColor

        glyphLabel.text = label
        glyphLabel.textColor = dark ? .white : .black
        glyphLabel.frame = bounds.offsetBy(dx: 0, dy: -1.0)
        isHidden = false
    }
}
#endif
