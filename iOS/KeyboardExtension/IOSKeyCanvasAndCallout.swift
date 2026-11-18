#if os(iOS)
import CoreHaptics
import UIKit

/// Low-latency Taptic feedback controller combining `CoreHaptics` crisp high-sharpness transients
/// (`playsHapticsOnly = true`, zero audio-session ducking) with a pre-warmed `.rigid` fallback ring.
@MainActor
final class IOSKeyboardFeedbackController {
    private var engine: CHHapticEngine?
    private var keyTapPlayer: CHHapticPatternPlayer?
    private var softTickPlayer: CHHapticPatternPlayer?
    private var engineRunning = false

    private var rigidRing: [UIImpactFeedbackGenerator] = []
    private var ringIndex = 0
    private let selectionGenerator = UISelectionFeedbackGenerator()

    init(attachingTo view: UIView? = nil) {
        for _ in 0..<3 {
            if #available(iOS 17.5, *), let view {
                rigidRing.append(UIImpactFeedbackGenerator(style: .rigid, view: view))
            } else {
                rigidRing.append(UIImpactFeedbackGenerator(style: .rigid))
            }
        }
        setupCoreHapticsIfSupported()
    }

    private func setupCoreHapticsIfSupported() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let eng = try CHHapticEngine()
            eng.playsHapticsOnly = true
            eng.isAutoShutdownEnabled = false
            eng.stoppedHandler = { [weak self] _ in
                Task { @MainActor in
                    self?.engineRunning = false
                }
            }
            eng.resetHandler = { [weak self] in
                Task { @MainActor in
                    self?.rebuildPlayersAndStart()
                }
            }
            self.engine = eng
            rebuildPlayersAndStart()
        } catch {
            self.engine = nil
            self.engineRunning = false
        }
    }

    private func rebuildPlayersAndStart() {
        guard let eng = engine else { return }
        do {
            let keyEvent = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.45),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.88),
                ],
                relativeTime: 0
            )
            let softEvent = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.31),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.80),
                ],
                relativeTime: 0
            )
            keyTapPlayer = try eng.makePlayer(with: CHHapticPattern(events: [keyEvent], parameters: []))
            softTickPlayer = try eng.makePlayer(with: CHHapticPattern(events: [softEvent], parameters: []))
            try eng.start()
            engineRunning = true
        } catch {
            engineRunning = false
        }
    }

    func prepare() {
        for gen in rigidRing {
            gen.prepare()
        }
        selectionGenerator.prepare()
        if let eng = engine, !engineRunning {
            do {
                try eng.start()
                engineRunning = true
            } catch {
                engineRunning = false
            }
        }
    }

    func suspend() {
        engine?.stop(completionHandler: nil)
        engineRunning = false
    }

    func fireKeyDown() {
        UIDevice.current.playInputClick()
        if engineRunning, let player = keyTapPlayer {
            do {
                try player.start(atTime: CHHapticTimeImmediate)
                return
            } catch {
                engineRunning = false
            }
        }
        let gen = rigidRing[ringIndex % rigidRing.count]
        ringIndex &+= 1
        gen.impactOccurred(intensity: 0.42)
        gen.prepare()
    }

    func fireSoftStep(playClick: Bool) {
        if playClick {
            UIDevice.current.playInputClick()
        }
        if engineRunning, let player = softTickPlayer {
            do {
                try player.start(atTime: CHHapticTimeImmediate)
                return
            } catch {
                engineRunning = false
            }
        }
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }
}

/// Hardware-composited continuous-squircle (`CALayer`) keycap node:
/// zero `draw(_:)` backing bitmap, explicit `shadowPath` (zero offscreen pass), cached SF Symbols.
@MainActor
private final class IOSKeycapNodeView: UIView {
    private let primaryLabel = UILabel()
    private let symbolView = UIImageView()
    private let subscriptLabel = UILabel()

    private var lastBoundsSize: CGSize = .zero
    private(set) var currentSpec: IOSKeySpec?
    private var isDarkTheme = false
    private var isPressedState = false
    private var isGlyphCovered = false

    private static var symbolCache: [String: UIImage] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = IOSKeyboardLayoutEngine.keyCornerRadius
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 0.85)
        layer.shadowRadius = 0.65

        primaryLabel.textAlignment = .center
        primaryLabel.isUserInteractionEnabled = false

        symbolView.contentMode = .center
        symbolView.isUserInteractionEnabled = false

        subscriptLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        subscriptLabel.textAlignment = .right
        subscriptLabel.isUserInteractionEnabled = false

        addSubview(primaryLabel)
        addSubview(symbolView)
        addSubview(subscriptLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        spec: IOSKeySpec,
        dark: Bool,
        pressed: Bool,
        glyphCovered: Bool
    ) {
        let frameChanged = (frame != spec.frame)
        if frameChanged {
            UIView.performWithoutAnimation {
                self.frame = spec.frame
                if bounds.size != lastBoundsSize {
                    lastBoundsSize = bounds.size
                    layer.shadowPath = UIBezierPath(
                        roundedRect: bounds,
                        cornerRadius: IOSKeyboardLayoutEngine.keyCornerRadius
                    ).cgPath
                }
                layoutSublayersOfKeycap(spec: spec)
            }
        }

        let specOrThemeChanged = (currentSpec != spec) || (isDarkTheme != dark)
        currentSpec = spec
        isDarkTheme = dark

        if specOrThemeChanged {
            UIView.performWithoutAnimation {
                updateContent(spec: spec, dark: dark)
                layoutSublayersOfKeycap(spec: spec)
            }
        }

        applyPressVisuals(pressed: pressed, glyphCovered: glyphCovered, spec: spec, dark: dark, animatedRelease: !pressed && isPressedState)
        isPressedState = pressed
        isGlyphCovered = glyphCovered
    }

    private func layoutSublayersOfKeycap(spec: IOSKeySpec) {
        let b = bounds
        let yNudge: CGFloat
        switch spec.kind {
        case .letter: yNudge = -1.1
        case .symbol: yNudge = -0.5
        default: yNudge = 0.0
        }
        primaryLabel.frame = b.offsetBy(dx: 0, dy: yNudge)
        symbolView.frame = b
        subscriptLabel.frame = CGRect(x: b.width - 28, y: b.height - 18.5, width: 21, height: 14)
    }

    private func updateContent(spec: IOSKeySpec, dark: Bool) {
        let fgColor: UIColor = spec.isBlueAccent ? .white : (dark ? .white : .black)
        let subColor: UIColor = dark
            ? UIColor(white: 1.0, alpha: 0.42)
            : UIColor(red: 0.58, green: 0.59, blue: 0.62, alpha: 1.0)

        if let symName = spec.systemSymbol {
            primaryLabel.isHidden = true
            symbolView.isHidden = false
            let cacheKey = symName
            let template: UIImage?
            if let cached = Self.symbolCache[cacheKey] {
                template = cached
            } else {
                let cfg = UIImage.SymbolConfiguration(pointSize: 18.5, weight: .regular)
                let img = UIImage(systemName: symName, withConfiguration: cfg)?.withRenderingMode(.alwaysTemplate)
                if let img { Self.symbolCache[cacheKey] = img }
                template = img
            }
            symbolView.image = template
            symbolView.tintColor = fgColor
        } else if !spec.primaryLabel.isEmpty {
            symbolView.isHidden = true
            primaryLabel.isHidden = false
            if let secondary = spec.secondaryInlineLabel, !secondary.isEmpty {
                let attr = NSMutableAttributedString(
                    string: spec.primaryLabel,
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 15.5, weight: .medium),
                        .foregroundColor: fgColor,
                    ]
                )
                attr.append(
                    NSAttributedString(
                        string: secondary,
                        attributes: [
                            .font: UIFont.systemFont(ofSize: 11.5, weight: .regular),
                            .foregroundColor: subColor,
                        ]
                    )
                )
                primaryLabel.attributedText = attr
            } else {
                primaryLabel.attributedText = nil
                let fontSize: CGFloat
                let weight: UIFont.Weight
                switch spec.kind {
                case .letter:
                    fontSize = 23.0
                    weight = .regular
                case .symbol(let s):
                    fontSize = s.count > 1 ? 16.0 : 21.0
                    weight = .regular
                case .returnKey:
                    fontSize = 15.5
                    weight = spec.isBlueAccent ? .semibold : .regular
                default:
                    fontSize = 16.0
                    weight = .regular
                }
                primaryLabel.font = .systemFont(ofSize: fontSize, weight: weight)
                primaryLabel.textColor = fgColor
                primaryLabel.text = spec.primaryLabel
            }
        } else {
            primaryLabel.isHidden = true
            symbolView.isHidden = true
        }

        if let sub = spec.cornerSubscript, !sub.isEmpty {
            subscriptLabel.isHidden = false
            subscriptLabel.text = sub
            subscriptLabel.textColor = subColor
        } else {
            subscriptLabel.isHidden = true
        }
    }

    func applyPressVisuals(
        pressed: Bool,
        glyphCovered: Bool,
        spec: IOSKeySpec,
        dark: Bool,
        animatedRelease: Bool
    ) {
        let normalBg: UIColor = spec.isBlueAccent
            ? .systemBlue
            : (dark ? UIColor(red: 0.28, green: 0.28, blue: 0.30, alpha: 1.0) : .white)
        let pressedBg: UIColor = spec.isBlueAccent
            ? UIColor.systemBlue.withAlphaComponent(0.80)
            : (dark
                ? UIColor(red: 0.20, green: 0.20, blue: 0.23, alpha: 1.0)
                : UIColor(red: 214.0 / 255.0, green: 216.0 / 255.0, blue: 222.0 / 255.0, alpha: 1.0))

        let targetBg = pressed ? pressedBg : normalBg
        let targetShadowOpacity: Float = pressed ? 0.02 : (dark ? 0.32 : 0.15)
        let targetTransform: CGAffineTransform = pressed
            ? CGAffineTransform(translationX: 0, y: 0.45)
            : .identity
        let contentAlpha: CGFloat = glyphCovered ? 0.0 : 1.0

        let applyBlock = {
            self.backgroundColor = targetBg
            self.layer.shadowOpacity = targetShadowOpacity
            self.transform = targetTransform
            self.primaryLabel.alpha = contentAlpha
        }

        if animatedRelease {
            UIView.animate(
                withDuration: 0.065,
                delay: 0,
                options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState],
                animations: applyBlock
            )
        } else {
            UIView.performWithoutAnimation(applyBlock)
        }
    }
}

/// 120Hz hardware-composited iOS 26 4-row keyboard canvas with true per-finger rollover tracking
/// and sticky press-lock hysteresis (eliminating lift-off flick drops & cross-key misfires).
final class IOSKeyCanvasView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }

    var onKeyTouchDown: ((IOSKeySpec) -> Void)?
    var onLetterPress: ((IOSKeySpec, CGPoint) -> Void)?
    var onEndLetterPreview: (() -> Void)?
    var onKeySlidePreview: ((IOSKeySpec?) -> Void)?
    var onKeyTouchUp: ((IOSKeySpec, CGPoint) -> Void)?
    var onKeyTouchCancel: (() -> Void)?
    var onTrackpadStateChanged: ((Bool) -> Void)?
    var onRestorePlane: (() -> Void)?
    var onTrackpadMove: ((Int, Int) -> Void)?

    private struct TrackedTouch {
        let beganTimestamp: TimeInterval
        let initialPoint: CGPoint
        var currentPoint: CGPoint
        let initialKey: IOSKeySpec
        var currentKey: IOSKeySpec
        let isPlaneSlide: Bool
        let startedOnSpace: Bool
        var committedByRollover: Bool = false
    }

    private var snapshot: IOSKeyboardLayoutEngine.LayoutSnapshot?
    var validNextMask: UInt32 = 0x03FF_FFFF
    /// ID of Row-0 key whose glyph is seamlessly covered by the docked callout silhouette.
    var coveredCalloutKeyId: String? {
        didSet {
            if oldValue != coveredCalloutKeyId {
                syncKeycapPressStates()
            }
        }
    }

    private var keycapNodes: [IOSKeycapNodeView] = []
    private var trackedTouches: [ObjectIdentifier: TrackedTouch] = [:]
    private var spaceHoldTimer: Timer?
    private var spaceHoldTouchId: ObjectIdentifier?
    private var trackpad = SpaceTrackpadAccumulator()
    private var isDark: Bool = false

    init() {
        super.init(frame: .zero, inputViewStyle: .keyboard)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        clipsToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(dark: Bool) {
        guard isDark != dark else { return }
        isDark = dark
        rebuildOrSyncKeycapNodes()
    }

    func updateSnapshot(_ snap: IOSKeyboardLayoutEngine.LayoutSnapshot) {
        self.snapshot = snap
        rebuildOrSyncKeycapNodes()
    }

    private func rebuildOrSyncKeycapNodes() {
        guard let snap = snapshot else { return }
        while keycapNodes.count < snap.keys.count {
            let node = IOSKeycapNodeView(frame: .zero)
            addSubview(node)
            keycapNodes.append(node)
        }
        if keycapNodes.count > snap.keys.count {
            for idx in snap.keys.count..<keycapNodes.count {
                keycapNodes[idx].isHidden = true
            }
        }
        let pressedIds = currentPressedKeyIds()
        for (idx, spec) in snap.keys.enumerated() {
            let node = keycapNodes[idx]
            node.isHidden = false
            let isPressed = pressedIds.contains(spec.id)
            let isCovered = isPressed && (coveredCalloutKeyId == spec.id)
            node.configure(spec: spec, dark: isDark, pressed: isPressed, glyphCovered: isCovered)
        }
    }

    private func currentPressedKeyIds() -> Set<String> {
        if trackpad.isActive { return [] }
        var ids = Set<String>()
        for t in trackedTouches.values where !t.committedByRollover {
            ids.insert(t.currentKey.id)
        }
        return ids
    }

    private func syncKeycapPressStates() {
        guard let snap = snapshot else { return }
        let pressedIds = currentPressedKeyIds()
        for (idx, spec) in snap.keys.enumerated() where idx < keycapNodes.count {
            let node = keycapNodes[idx]
            let isPressed = pressedIds.contains(spec.id)
            let isCovered = isPressed && (coveredCalloutKeyId == spec.id)
            node.configure(spec: spec, dark: isDark, pressed: isPressed, glyphCovered: isCovered)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let ordered = touches.sorted(by: { $0.timestamp < $1.timestamp })
        for touch in ordered {
            // 1. Multi-touch Rollover: commit any earlier active non-slide touch in exact press order!
            let pendingIds = trackedTouches
                .filter {
                    let state = $0.value
                    if case .letter = state.initialKey.kind { return false }
                    return !state.committedByRollover && !state.isPlaneSlide
                        && !(state.startedOnSpace && trackpad.isActive)
                }
                .sorted(by: { $0.value.beganTimestamp < $1.value.beganTimestamp })
                .map(\.key)

            for oldId in pendingIds {
                guard var oldState = trackedTouches[oldId] else { continue }
                if oldState.startedOnSpace && spaceHoldTouchId == oldId {
                    spaceHoldTimer?.invalidate()
                    spaceHoldTimer = nil
                    spaceHoldTouchId = nil
                }
                oldState.committedByRollover = true
                trackedTouches[oldId] = oldState
                let cleanPt = (oldState.currentKey.id == oldState.initialKey.id)
                    ? oldState.initialPoint
                    : oldState.currentPoint
                onKeyTouchUp?(oldState.currentKey, cleanPt)
            }

            // 2. Hit-test new touch against freshly updated snapshot & dynamic validNextMask
            let point = touch.location(in: self)
            guard let snap = snapshot,
                  let hit = IOSKeyboardLayoutEngine.hitTest(
                      point: point,
                      in: snap,
                      validNextMask: validNextMask
                  ) else {
                continue
            }

            let id = ObjectIdentifier(touch)
            let isPlane: Bool
            if case .planeSwitch = hit.kind { isPlane = true } else { isPlane = false }
            let isSpace = (hit.kind == .space)

            let state = TrackedTouch(
                beganTimestamp: touch.timestamp,
                initialPoint: point,
                currentPoint: point,
                initialKey: hit,
                currentKey: hit,
                isPlaneSlide: isPlane,
                startedOnSpace: isSpace,
                committedByRollover: false
            )
            trackedTouches[id] = state

            if isSpace {
                spaceHoldTimer?.invalidate()
                spaceHoldTouchId = id
                let timer = Timer(timeInterval: 0.28, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self,
                              let activeId = self.spaceHoldTouchId,
                              let st = self.trackedTouches[activeId],
                              !st.committedByRollover else { return }
                        self.trackpad.begin(at: st.currentPoint, timestamp: ProcessInfo.processInfo.systemUptime)
                        self.onTrackpadStateChanged?(true)
                        self.syncKeycapPressStates()
                    }
                }
                spaceHoldTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }

            syncKeycapPressStates()
            onKeyTouchDown?(hit)
            if case .letter = hit.kind {
                onLetterPress?(hit, point)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let snap = snapshot else { return }
        for touch in touches {
            let id = ObjectIdentifier(touch)
            guard var state = trackedTouches[id], !state.committedByRollover else { continue }
            if case .letter = state.initialKey.kind { continue }
            if state.initialKey.kind == .backspace { continue }
            let pt = touch.location(in: self)
            state.currentPoint = pt

            // 1. Hold-and-slide from `123` / `#+=` to pick a number/punctuation and auto-return
            if state.isPlaneSlide {
                if let hit = IOSKeyboardLayoutEngine.hitTest(point: pt, in: snap), hit.id != state.currentKey.id {
                    state.currentKey = hit
                    trackedTouches[id] = state
                    syncKeycapPressStates()
                    onKeySlidePreview?(hit)
                } else {
                    trackedTouches[id] = state
                }
                continue
            }

            // 2. Spacebar 2D trackpad cursor drag
            if state.startedOnSpace {
                trackedTouches[id] = state
                if !trackpad.isActive && hypot(pt.x - state.initialPoint.x, pt.y - state.initialPoint.y) > 13 {
                    if spaceHoldTouchId == id {
                        spaceHoldTimer?.invalidate()
                        spaceHoldTimer = nil
                    }
                }
                if trackpad.isActive {
                    let (dx, dy) = trackpad.update(point: pt, timestamp: touch.timestamp)
                    if dx != 0 || dy != 0 {
                        onTrackpadMove?(dx, dy)
                    }
                }
                continue
            }

            // 3. Sticky Press-Lock Hysteresis: ignore natural thumb lift-roll within expanded keep-zone!
            let keepRect = state.currentKey.frame.insetBy(dx: -9.5, dy: -12.5)
            if keepRect.contains(pt) {
                trackedTouches[id] = state
                continue
            }

            // Only switch keys on deliberate hold-slide, never on sub-85ms rapid lift flicks!
            let dt = touch.timestamp - state.beganTimestamp
            let dist = hypot(pt.x - state.initialPoint.x, pt.y - state.initialPoint.y)
            guard dt >= 0.085 || dist > 23.0 else {
                trackedTouches[id] = state
                continue
            }

            if pt.y < -34 {
                trackedTouches[id] = state
                onKeySlidePreview?(nil)
                continue
            }

            if let hit = IOSKeyboardLayoutEngine.hitTest(point: pt, in: snap, validNextMask: validNextMask),
               hit.id != state.currentKey.id {
                state.currentKey = hit
                trackedTouches[id] = state
                syncKeycapPressStates()
                onKeySlidePreview?(hit)
            } else {
                trackedTouches[id] = state
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let ordered = touches.sorted(by: { $0.timestamp < $1.timestamp })
        for touch in ordered {
            let id = ObjectIdentifier(touch)
            guard let state = trackedTouches.removeValue(forKey: id) else { continue }
            let pt = touch.location(in: self)

            if spaceHoldTouchId == id {
                spaceHoldTimer?.invalidate()
                spaceHoldTimer = nil
                spaceHoldTouchId = nil
            }

            if case .letter = state.initialKey.kind {
                let newestLetterStillDown = trackedTouches.values.contains { other in
                    guard case .letter = other.initialKey.kind else { return false }
                    return other.beganTimestamp > state.beganTimestamp
                }
                syncKeycapPressStates()
                if !newestLetterStillDown { onEndLetterPreview?() }
                continue
            }

            if state.committedByRollover {
                syncKeycapPressStates()
                continue
            }

            if state.startedOnSpace && trackpad.isActive {
                trackpad.end()
                onTrackpadStateChanged?(false)
                syncKeycapPressStates()
                continue
            }

            if state.isPlaneSlide {
                syncKeycapPressStates()
                guard let snap = snapshot,
                      let hit = IOSKeyboardLayoutEngine.hitTest(point: pt, in: snap) else {
                    onRestorePlane?()
                    onKeyTouchCancel?()
                    continue
                }
                if hit.id == state.initialKey.id {
                    onKeySlidePreview?(nil)
                    continue
                }
                if case .symbol(let sym) = hit.kind {
                    onKeyTouchUp?(hit, pt)
                    if sym.allSatisfy(\.isNumber) {
                        onRestorePlane?()
                    }
                } else {
                    onRestorePlane?()
                    onKeyTouchCancel?()
                }
                continue
            }

            // Deliberate swipe way off top edge cancels; slight flick into ribbon still commits cleanly!
            if pt.y < -34 {
                syncKeycapPressStates()
                onKeyTouchCancel?()
                continue
            }

            let commitPt = (state.currentKey.id == state.initialKey.id) ? state.initialPoint : pt
            syncKeycapPressStates()
            onKeyTouchUp?(state.currentKey, commitPt)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            guard let state = trackedTouches.removeValue(forKey: id) else { continue }
            if spaceHoldTouchId == id {
                spaceHoldTimer?.invalidate()
                spaceHoldTimer = nil
                spaceHoldTouchId = nil
            }
            if state.isPlaneSlide {
                onRestorePlane?()
            }
            if state.startedOnSpace && trackpad.isActive {
                trackpad.end()
                onTrackpadStateChanged?(false)
            }
        }
        syncKeycapPressStates()
        if trackedTouches.values.allSatisfy(\.committedByRollover) {
            onKeyTouchCancel?()
        }
    }
}

/// Full-size iOS 26 Key Callout Bubble with spring micro-motion:
/// - Row 1 & Row 2: standalone `61.33 x 65.0pt` continuous squircle hovering `4.0pt` above pressed keycap.
/// - Row 0 (`q..p`): full `61.33pt` head (`36.5pt` glyph, zero shrinking!) seamlessly tapering into the
///   pressed keycap base so it neither gets clipped by the XPC viewport nor cuts the underlying glyph in half.
final class IOSKeyCalloutView: UIView {
    private let shapeLayer = CAShapeLayer()
    private let glyphLabel = UILabel()
    private var dismissWorkItem: DispatchWorkItem?
    private(set) var coveredKeyId: String?

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 61.33, height: 65.0))
        isOpaque = false
        isUserInteractionEnabled = false
        clipsToBounds = false

        shapeLayer.shadowColor = UIColor.black.cgColor
        shapeLayer.shadowOffset = CGSize(width: 0, height: 3.5)
        shapeLayer.shadowRadius = 11.0
        layer.addSublayer(shapeLayer)

        glyphLabel.font = .systemFont(ofSize: 36.5, weight: .regular)
        glyphLabel.textAlignment = .center
        addSubview(glyphLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func hideImmediately() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        layer.removeAllAnimations()
        coveredKeyId = nil
        alpha = 1.0
        transform = .identity
        isHidden = true
    }

    func releasePreview(onCleared: (() -> Void)? = nil) {
        dismissWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.animate(
                withDuration: 0.052,
                delay: 0,
                options: [.curveEaseIn, .beginFromCurrentState, .allowUserInteraction],
                animations: {
                    self.alpha = 0.0
                    self.transform = CGAffineTransform(scaleX: 0.94, y: 0.94).translatedBy(x: 0, y: 2.0)
                },
                completion: { finished in
                    if finished {
                        self.coveredKeyId = nil
                        self.isHidden = true
                        self.alpha = 1.0
                        self.transform = .identity
                        onCleared?()
                    }
                }
            )
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.038, execute: item)
    }

    /// Presents the full-size callout and returns `true` when Row 0's docked skirt covers the underlying keycap glyph.
    @discardableResult
    func present(label: String, keyId: String, over keyFrameInSuperview: CGRect, dark: Bool) -> Bool {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        let wasHidden = isHidden || alpha < 0.2
        layer.removeAllAnimations()

        let headW: CGFloat = max(61.33, keyFrameInSuperview.width * 1.66)
        let headH: CGFloat = 65.0
        let hoverGap: CGFloat = 4.0
        let superW = superview?.bounds.width ?? 440

        let headMinX = min(
            max(3.5, keyFrameInSuperview.midX - headW * 0.5),
            max(3.5, superW - headW - 3.5)
        )
        let headMaxX = headMinX + headW
        let rawFloatingY = keyFrameInSuperview.minY - hoverGap - headH

        let fillCol = dark
            ? UIColor(red: 0.35, green: 0.35, blue: 0.38, alpha: 1.0)
            : UIColor.white
        let strokeCol = dark
            ? UIColor.white.withAlphaComponent(0.15)
            : UIColor.black.withAlphaComponent(0.06)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let isDockedRow0 = (rawFloatingY < 1.5)

        if !isDockedRow0 {
            // Row 1 & Row 2: pure standalone floating iOS 26 squircle!
            coveredKeyId = nil
            let targetFrame = CGRect(x: headMinX, y: rawFloatingY, width: headW, height: headH)
            UIView.performWithoutAnimation {
                self.transform = .identity
                self.frame = targetFrame
                let p = UIBezierPath(roundedRect: CGRect(origin: .zero, size: targetFrame.size), cornerRadius: 13.5)
                shapeLayer.frame = bounds
                shapeLayer.path = p.cgPath
                shapeLayer.shadowPath = p.cgPath
                glyphLabel.font = .systemFont(ofSize: 36.5, weight: .regular)
                glyphLabel.frame = CGRect(x: 0, y: -1.0, width: headW, height: headH)
            }
        } else {
            // Row 0 (`q..p`): full-size callout docked seamlessly into exact keycap base!
            // Align outer edge flush with `q`/`p` keycap (`6.67pt`) so it sits cleanly inside the 26pt tray corner,
            // and place waist at `46.5..58.5pt` so descenders (`q`, `y`, `p`) have generous room above the taper.
            coveredKeyId = keyId
            let topY: CGFloat = 3.5
            let botY: CGFloat = keyFrameInSuperview.maxY
            let isLeftEdge = (keyFrameInSuperview.minX < 18.0)
            let isRightEdge = (keyFrameInSuperview.maxX > superW - 18.0)
            let row0HeadW: CGFloat = (isLeftEdge || isRightEdge) ? 55.0 : headW
            let row0HeadMinX: CGFloat
            if isLeftEdge {
                row0HeadMinX = keyFrameInSuperview.minX
            } else if isRightEdge {
                row0HeadMinX = keyFrameInSuperview.maxX - row0HeadW
            } else {
                row0HeadMinX = keyFrameInSuperview.midX - row0HeadW * 0.5
            }
            let row0HeadMaxX = row0HeadMinX + row0HeadW

            let unionMinX = min(row0HeadMinX, keyFrameInSuperview.minX)
            let unionMaxX = max(row0HeadMaxX, keyFrameInSuperview.maxX)
            let totalW = unionMaxX - unionMinX
            let totalH = botY - topY

            let hL = row0HeadMinX - unionMinX
            let hR = row0HeadMaxX - unionMinX
            let kL = keyFrameInSuperview.minX - unionMinX
            let kR = keyFrameInSuperview.maxX - unionMinX

            let waistTop: CGFloat = 46.5
            let waistBot: CGFloat = 58.5
            let path = Self.makeDockedBalloonPath(
                headLeft: hL,
                headRight: hR,
                keyLeft: kL,
                keyRight: kR,
                waistTop: waistTop,
                waistBot: waistBot,
                totalHeight: totalH,
                topRadius: 13.0,
                bottomRadius: IOSKeyboardLayoutEngine.keyCornerRadius
            )

            UIView.performWithoutAnimation {
                self.transform = .identity
                self.frame = CGRect(x: unionMinX, y: topY, width: totalW, height: totalH)
                shapeLayer.frame = bounds
                shapeLayer.path = path
                shapeLayer.shadowPath = path
                glyphLabel.font = .systemFont(ofSize: 35.5, weight: .regular)
                glyphLabel.frame = CGRect(x: hL, y: -1.5, width: row0HeadW, height: 49.0)
            }
        }

        shapeLayer.fillColor = fillCol.cgColor
        shapeLayer.strokeColor = strokeCol.cgColor
        shapeLayer.lineWidth = 0.5
        shapeLayer.shadowOpacity = dark ? 0.40 : 0.15
        CATransaction.commit()

        glyphLabel.text = label
        glyphLabel.textColor = dark ? .white : .black
        alpha = 1.0
        isHidden = false

        if wasHidden {
            transform = CGAffineTransform(scaleX: 0.91, y: 0.91).translatedBy(x: 0, y: 3.5)
            UIView.animate(
                withDuration: 0.072,
                delay: 0,
                usingSpringWithDamping: 0.84,
                initialSpringVelocity: 0.5,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: {
                    self.transform = .identity
                }
            )
        }
        return isDockedRow0
    }

    private static func makeDockedBalloonPath(
        headLeft: CGFloat,
        headRight: CGFloat,
        keyLeft: CGFloat,
        keyRight: CGFloat,
        waistTop: CGFloat,
        waistBot: CGFloat,
        totalHeight: CGFloat,
        topRadius rT: CGFloat,
        bottomRadius rB: CGFloat
    ) -> CGPath {
        let p = UIBezierPath()
        let midY = (waistTop + waistBot) * 0.5

        p.move(to: CGPoint(x: headLeft + rT, y: 0))
        p.addLine(to: CGPoint(x: headRight - rT, y: 0))
        p.addQuadCurve(to: CGPoint(x: headRight, y: rT), controlPoint: CGPoint(x: headRight, y: 0))
        p.addLine(to: CGPoint(x: headRight, y: waistTop))

        // Right waist curve into keycap right edge
        p.addCurve(
            to: CGPoint(x: keyRight, y: waistBot),
            controlPoint1: CGPoint(x: headRight, y: midY),
            controlPoint2: CGPoint(x: keyRight, y: midY)
        )
        p.addLine(to: CGPoint(x: keyRight, y: totalHeight - rB))
        p.addQuadCurve(
            to: CGPoint(x: keyRight - rB, y: totalHeight),
            controlPoint: CGPoint(x: keyRight, y: totalHeight)
        )
        p.addLine(to: CGPoint(x: keyLeft + rB, y: totalHeight))
        p.addQuadCurve(
            to: CGPoint(x: keyLeft, y: totalHeight - rB),
            controlPoint: CGPoint(x: keyLeft, y: totalHeight)
        )
        p.addLine(to: CGPoint(x: keyLeft, y: waistBot))

        // Left waist curve back up into head left edge
        p.addCurve(
            to: CGPoint(x: headLeft, y: waistTop),
            controlPoint1: CGPoint(x: keyLeft, y: midY),
            controlPoint2: CGPoint(x: headLeft, y: midY)
        )
        p.addLine(to: CGPoint(x: headLeft, y: rT))
        p.addQuadCurve(to: CGPoint(x: headLeft + rT, y: 0), controlPoint: CGPoint(x: headLeft, y: 0))
        p.close()
        return p.cgPath
    }
}
#endif
