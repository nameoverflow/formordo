#if os(iOS)
import UIKit

@objc(KeyboardViewController)
public final class KeyboardViewController: UIInputViewController {
    private lazy var bridge = WubiBridge()
    private var layoutEngine = IOSKeyboardLayoutEngine()

    private let glassBackdrop = UIView()
    private let ribbonView = IOSCandidateRibbonView()
    private let keyCanvas = IOSKeyCanvasView()
    private let expandedGrid = IOSExpandedCandidateView()
    private let calloutView = IOSKeyCalloutView()

    private var heightConstraint: NSLayoutConstraint?
    private var ribbonHeightConstraint: NSLayoutConstraint?
    private var saveUserDataTimer: Timer?
    private var backspaceTimer: Timer?
    private var backspaceHoldStart: TimeInterval = 0
    private var lastVisualKeySignature: VisualLayoutSignature?
    private var planeBeforePress: IOSKeyPlane = .letters
    private var markedCode = ""

    private lazy var feedback = IOSKeyboardFeedbackController(attachingTo: keyCanvas)

    private struct VisualLayoutSignature: Equatable {
        let plane: IOSKeyPlane
        let shiftState: IOSShiftState
        let asciiMode: Bool
        let showInlineGlobeKey: Bool
        let returnRole: IOSReturnKeyRole
        let isTrackpadActive: Bool
        let size: CGSize
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: KeyboardViewController, _) in
                self.syncProxyTraits()
            }
        }
        syncEngineToUI()
    }

    public override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        .all
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        feedback.prepare()
        bridge.loadConfigAndUser()
        applyDesiredTrayDimensions()
        syncEngineToUI()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyDesiredTrayDimensions()
        disableTouchDelayOnContainerGestures()
    }

    public override func updateViewConstraints() {
        super.updateViewConstraints()
        applyDesiredTrayDimensions()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopBackspaceRepeat()
        keyCanvas.resetAllTouches()
        calloutView.hideImmediately()
        saveUserDataTimer?.invalidate()
        cancelMarkedCode()
        bridge.clearComposition()
        bridge.flushUserDataIfNeeded(refreshPublishedLists: false)
        feedback.suspend()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyDesiredTrayDimensions()
        refreshKeyboardLayout()
    }

    private func applyDesiredTrayDimensions() {
        let width = view.bounds.width > 10 ? view.bounds.width : UIScreen.main.bounds.width
        let isLandscape = width > 540
        // 53pt candidate ribbon + 220pt 4-row keyboard (`keyH = 45pt`, `rowGap = 11pt`) = 273pt matching iOS 26 native height (`608..881pt`).
        let targetH: CGFloat = isLandscape ? 204 : 273
        let targetRibbonH: CGFloat = isLandscape
            ? IOSKeyboardLayoutEngine.landscapeCandidateBarHeight
            : IOSKeyboardLayoutEngine.candidateBarHeight
        var changed = false
        if heightConstraint?.constant != targetH {
            heightConstraint?.constant = targetH
            changed = true
        }
        if ribbonHeightConstraint?.constant != targetRibbonH {
            ribbonHeightConstraint?.constant = targetRibbonH
            changed = true
        }
        if changed {
            inputView?.setNeedsUpdateConstraints()
        }
    }

    public override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        syncProxyTraits()
    }

    private func setupViews() {
        guard let inputView = self.inputView else { return }
        inputView.allowsSelfSizing = true
        inputView.clipsToBounds = false
        view.clipsToBounds = false

        glassBackdrop.translatesAutoresizingMaskIntoConstraints = false
        glassBackdrop.layer.cornerRadius = IOSKeyboardLayoutEngine.trayTopCornerRadius
        glassBackdrop.layer.cornerCurve = .continuous
        glassBackdrop.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        glassBackdrop.isUserInteractionEnabled = false

        ribbonView.translatesAutoresizingMaskIntoConstraints = false
        ribbonView.accessibilityIdentifier = "PrisWubiRibbon"
        keyCanvas.translatesAutoresizingMaskIntoConstraints = false
        keyCanvas.accessibilityIdentifier = "PrisWubiKeyCanvas"
        expandedGrid.translatesAutoresizingMaskIntoConstraints = false

        expandedGrid.isHidden = true
        calloutView.isHidden = true

        inputView.addSubview(glassBackdrop)
        inputView.addSubview(keyCanvas)
        inputView.addSubview(ribbonView)
        inputView.addSubview(expandedGrid)
        inputView.addSubview(calloutView)

        let hc = inputView.heightAnchor.constraint(equalToConstant: 273)
        hc.priority = UILayoutPriority(999)
        self.heightConstraint = hc
        let rhc = ribbonView.heightAnchor.constraint(equalToConstant: IOSKeyboardLayoutEngine.candidateBarHeight)
        self.ribbonHeightConstraint = rhc

        NSLayoutConstraint.activate([
            hc,
            glassBackdrop.topAnchor.constraint(equalTo: inputView.topAnchor),
            glassBackdrop.leadingAnchor.constraint(equalTo: inputView.leadingAnchor),
            glassBackdrop.trailingAnchor.constraint(equalTo: inputView.trailingAnchor),
            glassBackdrop.bottomAnchor.constraint(equalTo: inputView.bottomAnchor),

            ribbonView.topAnchor.constraint(equalTo: inputView.topAnchor),
            ribbonView.leadingAnchor.constraint(equalTo: inputView.leadingAnchor),
            ribbonView.trailingAnchor.constraint(equalTo: inputView.trailingAnchor),
            rhc,

            keyCanvas.topAnchor.constraint(equalTo: ribbonView.bottomAnchor),
            keyCanvas.leadingAnchor.constraint(equalTo: inputView.leadingAnchor),
            keyCanvas.trailingAnchor.constraint(equalTo: inputView.trailingAnchor),
            keyCanvas.bottomAnchor.constraint(equalTo: inputView.bottomAnchor),

            expandedGrid.topAnchor.constraint(equalTo: ribbonView.bottomAnchor),
            expandedGrid.leadingAnchor.constraint(equalTo: inputView.leadingAnchor),
            expandedGrid.trailingAnchor.constraint(equalTo: inputView.trailingAnchor),
            expandedGrid.bottomAnchor.constraint(equalTo: inputView.bottomAnchor),
        ])

        wireCallbacks()
        syncProxyTraits()
    }

    private func presentCalloutIfAppropriate(for spec: IOSKeySpec) {
        guard !layoutEngine.isTrackpadActive else {
            calloutView.hideImmediately()
            keyCanvas.coveredCalloutKeyId = nil
            return
        }
        switch spec.kind {
        case .letter:
            let frameInRoot = keyCanvas.convert(spec.frame, to: inputView)
            let isDocked = calloutView.present(
                label: spec.primaryLabel,
                keyId: spec.id,
                over: frameInRoot,
                dark: isDarkAppearance
            )
            keyCanvas.coveredCalloutKeyId = isDocked ? spec.id : nil
        case .symbol(let sym) where sym.count <= 2:
            let frameInRoot = keyCanvas.convert(spec.frame, to: inputView)
            let isDocked = calloutView.present(
                label: spec.primaryLabel,
                keyId: spec.id,
                over: frameInRoot,
                dark: isDarkAppearance
            )
            keyCanvas.coveredCalloutKeyId = isDocked ? spec.id : nil
        default:
            calloutView.hideImmediately()
            keyCanvas.coveredCalloutKeyId = nil
        }
    }

    private func wireCallbacks() {
        keyCanvas.onKeyTouchDown = { [weak self] spec in
            guard let self else { return }
            self.feedback.fireKeyDown()
            switch spec.kind {
            case .letter, .symbol:
                self.presentCalloutIfAppropriate(for: spec)
            case .planeSwitch(let plane, _):
                self.calloutView.hideImmediately()
                self.keyCanvas.coveredCalloutKeyId = nil
                self.planeBeforePress = self.layoutEngine.plane
                self.commitPendingFirstIfComposing()
                self.layoutEngine.switchPlane(plane)
                self.syncEngineToUI()
            case .backspace:
                self.calloutView.hideImmediately()
                self.keyCanvas.coveredCalloutKeyId = nil
                self.performBackspace()
                self.startBackspaceRepeat()
            default:
                self.calloutView.hideImmediately()
                self.keyCanvas.coveredCalloutKeyId = nil
            }
        }

        keyCanvas.onKeySlidePreview = { [weak self] spec in
            guard let self else { return }
            if let spec {
                self.feedback.fireSoftStep(playClick: false)
                self.presentCalloutIfAppropriate(for: spec)
            } else {
                self.calloutView.hideImmediately()
                self.keyCanvas.coveredCalloutKeyId = nil
            }
        }

        keyCanvas.onRestorePlane = { [weak self] in
            guard let self else { return }
            self.layoutEngine.switchPlane(self.planeBeforePress)
            self.refreshKeyboardLayout()
        }

        keyCanvas.onKeyTouchCancel = { [weak self] in
            self?.calloutView.hideImmediately()
            self?.keyCanvas.coveredCalloutKeyId = nil
            self?.stopBackspaceRepeat()
        }

        keyCanvas.onKeyTouchUp = { [weak self] spec, rawPointInCanvas in
            guard let self else { return }
            self.keyCanvas.coveredCalloutKeyId = nil
            self.calloutView.releasePreview()
            self.stopBackspaceRepeat()
            self.handleKeyRelease(spec: spec, pointInCanvas: rawPointInCanvas)
        }

        keyCanvas.onTrackpadStateChanged = { [weak self] active in
            guard let self else { return }
            self.calloutView.hideImmediately()
            self.keyCanvas.coveredCalloutKeyId = nil
            self.layoutEngine.isTrackpadActive = active
            if active {
                self.commitPendingFirstIfComposing()
                self.syncEngineToUI()
                self.feedback.fireSoftStep(playClick: false)
            }
            self.refreshKeyboardLayout()
        }

        keyCanvas.onTrackpadMove = { [weak self] dxSteps, dySteps in
            guard let self, self.bridge.state.preedit.isEmpty else { return }
            var moved = false
            if dxSteps != 0 {
                self.textDocumentProxy.adjustTextPosition(byCharacterOffset: dxSteps)
                moved = true
            }
            if dySteps != 0 {
                if self.moveCursorVertically(lines: dySteps) {
                    moved = true
                }
            }
            if moved {
                self.feedback.fireSoftStep(playClick: false)
            }
        }

        ribbonView.onSelectCandidate = { [weak self] relIdx in
            guard let self else { return }
            self.keyCanvas.flushPendingTouches()
            self.feedback.fireSoftStep(playClick: true)
            let out = self.bridge.selectCandidate(pageRelIndex: relIdx, timestampMs: Self.nowMs())
            self.applyEngineState(out)
        }

        ribbonView.onSelectStarterWord = { [weak self] word in
            guard let self else { return }
            self.keyCanvas.flushPendingTouches()
            self.feedback.fireSoftStep(playClick: true)
            self.textDocumentProxy.insertText(word)
        }

        ribbonView.onTapChevron = { [weak self] in
            guard let self else { return }
            self.keyCanvas.flushPendingTouches()
            self.feedback.fireSoftStep(playClick: true)
            guard !self.bridge.state.preedit.isEmpty else { return }
            self.expandedGrid.isHidden.toggle()
            let isExp = !self.expandedGrid.isHidden
            self.keyCanvas.isHidden = isExp
            if isExp {
                self.expandedGrid.reload(candidates: self.bridge.allCandidates(maxCount: 60), dark: self.isDarkAppearance)
            }
            self.ribbonView.setExpanded(isExp)
        }

        expandedGrid.onSelectAbsCandidate = { [weak self] absIdx in
            guard let self else { return }
            self.feedback.fireSoftStep(playClick: true)
            self.expandedGrid.isHidden = true
            self.keyCanvas.isHidden = false
            self.ribbonView.setExpanded(false)
            let out = self.bridge.selectAbsCandidate(absIndex: absIdx, timestampMs: Self.nowMs())
            self.applyEngineState(out)
        }

        expandedGrid.onCollapse = { [weak self] in
            self?.feedback.fireSoftStep(playClick: true)
            self?.expandedGrid.isHidden = true
            self?.keyCanvas.isHidden = false
            self?.ribbonView.setExpanded(false)
        }

        expandedGrid.onBackspace = { [weak self] in
            self?.feedback.fireKeyDown()
            self?.performBackspace()
            if let self, !self.expandedGrid.isHidden {
                if self.bridge.state.preedit.isEmpty {
                    self.expandedGrid.isHidden = true
                    self.keyCanvas.isHidden = false
                    self.ribbonView.setExpanded(false)
                } else {
                    self.expandedGrid.reload(candidates: self.bridge.allCandidates(maxCount: 60), dark: self.isDarkAppearance)
                }
            }
        }

        expandedGrid.onClear = { [weak self] in
            self?.feedback.fireSoftStep(playClick: true)
            self?.cancelMarkedCode()
            self?.bridge.clearComposition()
            self?.expandedGrid.isHidden = true
            self?.keyCanvas.isHidden = false
            self?.ribbonView.setExpanded(false)
            self?.syncEngineToUI()
        }
    }

    private func handleKeyRelease(spec: IOSKeySpec, pointInCanvas: CGPoint) {
        switch spec.kind {
        case .letter(let ascii):
            if layoutEngine.asciiMode || layoutEngine.shiftState.isUppercase {
                commitPendingFirstIfComposing()
                let ch = String(UnicodeScalar(ascii))
                let outStr = layoutEngine.shiftState.isUppercase ? ch.uppercased() : ch.lowercased()
                textDocumentProxy.insertText(outStr)
                layoutEngine.consumeOneShotShiftIfNeeded()
                refreshKeyboardLayout()
            } else {
                let out = bridge.pushTouch(
                    reportedAscii: ascii,
                    x: Float(pointInCanvas.x),
                    y: Float(pointInCanvas.y),
                    isNormalized: false,
                    timestampMs: Self.nowMs()
                )
                applyEngineState(out)
            }

        case .symbol(let sym):
            commitPendingFirstIfComposing()
            textDocumentProxy.insertText(sym)
            if IOSKeyboardLayoutEngine.shouldReturnToLettersAfterSymbol(sym, on: layoutEngine.plane) {
                layoutEngine.switchPlane(.letters)
            }
            syncEngineToUI()

        case .shift:
            layoutEngine.tapShift(at: ProcessInfo.processInfo.systemUptime)
            refreshKeyboardLayout()

        case .backspace:
            break

        case .planeSwitch(let targetPlane, _):
            commitPendingFirstIfComposing()
            layoutEngine.switchPlane(targetPlane)
            refreshKeyboardLayout()

        case .globe:
            commitPendingFirstIfComposing()
            advanceToNextInputMode()

        case .modeToggle:
            let out = bridge.toggleAsciiMode()
            if layoutEngine.plane != .letters {
                layoutEngine.switchPlane(.letters)
            }
            applyEngineState(out)

        case .space:
            if bridge.state.preedit.isEmpty {
                textDocumentProxy.insertText(" ")
            } else {
                let out = bridge.handleKey(keyCode: 0x31, scalar: 32, hasCmdOrCtrl: false, timestampMs: Self.nowMs())
                applyEngineState(out)
            }

        case .returnKey:
            if bridge.state.preedit.isEmpty {
                textDocumentProxy.insertText("\n")
            } else {
                let out = bridge.handleKey(keyCode: 0x24, scalar: 13, hasCmdOrCtrl: false, timestampMs: Self.nowMs())
                applyEngineState(out)
            }
        }
    }

    private func commitPendingFirstIfComposing() {
        guard !bridge.state.preedit.isEmpty else { return }
        if let first = bridge.state.candidates.first?.text {
            textDocumentProxy.insertText(first)
        } else {
            textDocumentProxy.insertText(bridge.state.preedit)
        }
        markedCode = ""
        bridge.clearComposition()
    }

    private func performBackspace(acceleratedChunk: Bool = false) {
        if !bridge.state.preedit.isEmpty {
            let out = bridge.handleKey(keyCode: 0x33, scalar: 0, hasCmdOrCtrl: false, timestampMs: Self.nowMs())
            applyEngineState(out)
            return
        }
        guard acceleratedChunk, let before = textDocumentProxy.documentContextBeforeInput, !before.isEmpty else {
            textDocumentProxy.deleteBackward()
            return
        }
        // Native-style accelerated hold-delete: erase up to 3 characters without crossing a newline in one jump
        if before.last == "\n" {
            textDocumentProxy.deleteBackward()
            return
        }
        var count = 0
        for ch in before.reversed() {
            if ch == "\n" || count >= 3 { break }
            count += 1
            if count >= 2 && (ch == " " || ch == "，" || ch == "。" || ch == "," || ch == ".") {
                break
            }
        }
        for _ in 0..<max(1, count) {
            textDocumentProxy.deleteBackward()
        }
    }

    private func startBackspaceRepeat() {
        stopBackspaceRepeat()
        backspaceHoldStart = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.068, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let held = ProcessInfo.processInfo.systemUptime - self.backspaceHoldStart
                guard held >= 0.36 else { return }
                let fastMode = (held >= 1.55) && self.bridge.state.preedit.isEmpty
                self.feedback.fireSoftStep(playClick: true)
                self.performBackspace(acceleratedChunk: fastMode)
            }
        }
        backspaceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopBackspaceRepeat() {
        backspaceTimer?.invalidate()
        backspaceTimer = nil
    }

    /// Move cursor vertically across lines in multi-line text views using `UITextDocumentProxy` context.
    private func moveCursorVertically(lines: Int) -> Bool {
        guard lines != 0 else { return false }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let after = textDocumentProxy.documentContextAfterInput ?? ""

        // Current column from most recent newline in `before`
        let currentCol: Int
        if let lastNL = before.lastIndex(of: "\n") {
            currentCol = before.distance(from: before.index(after: lastNL), to: before.endIndex)
        } else {
            currentCol = before.count
        }

        if lines < 0 {
            guard let lastNL = before.lastIndex(of: "\n") else {
                if !before.isEmpty {
                    textDocumentProxy.adjustTextPosition(byCharacterOffset: -before.count)
                    return true
                }
                return false
            }
            let prevPrefix = before[..<lastNL]
            let prevLineStart = prevPrefix.lastIndex(of: "\n").map { prevPrefix.index(after: $0) } ?? prevPrefix.startIndex
            let prevLineLen = prevPrefix.distance(from: prevLineStart, to: prevPrefix.endIndex)
            let targetCol = min(currentCol, prevLineLen)
            let delta = -(currentCol + 1 + (prevLineLen - targetCol))
            textDocumentProxy.adjustTextPosition(byCharacterOffset: delta)
            return true
        } else {
            guard let nextNL = after.firstIndex(of: "\n") else {
                if !after.isEmpty {
                    textDocumentProxy.adjustTextPosition(byCharacterOffset: after.count)
                    return true
                }
                return false
            }
            let toEndOfCurLine = after.distance(from: after.startIndex, to: nextNL)
            let rem = after[after.index(after: nextNL)...]
            let nextLineEnd = rem.firstIndex(of: "\n") ?? rem.endIndex
            let nextLineLen = rem.distance(from: rem.startIndex, to: nextLineEnd)
            let targetCol = min(currentCol, nextLineLen)
            let delta = toEndOfCurLine + 1 + targetCol
            textDocumentProxy.adjustTextPosition(byCharacterOffset: delta)
            return true
        }
    }

    private func cancelMarkedCode() {
        guard !markedCode.isEmpty else { return }
        textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        textDocumentProxy.unmarkText()
        markedCode = ""
    }

    private func applyEngineState(_ out: WubiActionState) {
        if !out.commitText.isEmpty {
            textDocumentProxy.insertText(out.commitText)
            markedCode = ""
            saveUserDataTimer?.invalidate()
            saveUserDataTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.bridge.flushUserDataIfNeeded(refreshPublishedLists: false) }
            }
        }
        if out.preedit.isEmpty {
            cancelMarkedCode()
        } else if out.preedit != markedCode {
            textDocumentProxy.setMarkedText(out.preedit, selectedRange: NSRange(location: out.preedit.utf16.count, length: 0))
            markedCode = out.preedit
        }
        if out.preedit.isEmpty && !expandedGrid.isHidden {
            expandedGrid.isHidden = true
            keyCanvas.isHidden = false
            ribbonView.setExpanded(false)
        }
        syncEngineToUI()
    }

    private func syncEngineToUI() {
        let st = bridge.state
        layoutEngine.asciiMode = st.asciiMode
        layoutEngine.schemaId = st.schemaId
        layoutEngine.isComposing = !st.preedit.isEmpty
        layoutEngine.validNextMask = st.validNextMask
        keyCanvas.validNextMask = st.validNextMask
        ribbonView.update(state: st, dark: isDarkAppearance)
        refreshKeyboardLayout()
    }

    private func syncProxyTraits() {
        layoutEngine.showInlineGlobeKey = self.needsInputModeSwitchKey
        layoutEngine.returnRole = Self.mapReturnKeyType(textDocumentProxy.returnKeyType)
        let dark = isDarkAppearance

        glassBackdrop.backgroundColor = .clear
        glassBackdrop.layer.borderWidth = 0

        keyCanvas.applyTheme(dark: dark)
        ribbonView.update(state: bridge.state, dark: dark)
        refreshKeyboardLayout()
    }

    private func refreshKeyboardLayout() {
        guard keyCanvas.bounds.width > 10, keyCanvas.bounds.height > 10 else { return }
        let sig = VisualLayoutSignature(
            plane: layoutEngine.plane,
            shiftState: layoutEngine.shiftState,
            asciiMode: layoutEngine.asciiMode,
            showInlineGlobeKey: layoutEngine.showInlineGlobeKey,
            returnRole: layoutEngine.returnRole,
            isTrackpadActive: layoutEngine.isTrackpadActive,
            size: keyCanvas.bounds.size
        )
        if lastVisualKeySignature == sig { return }
        lastVisualKeySignature = sig

        let snap = layoutEngine.computeLayout(in: keyCanvas.bounds.size)
        keyCanvas.updateSnapshot(snap)
        bridge.setKeyLayout(
            centers52: snap.centers52,
            originX: snap.originX,
            originY: snap.originY,
            pitchX: snap.pitchX,
            pitchY: snap.pitchY
        )
    }

    /// Ensure no ancestor container gesture recognizer inside our extension window holds `delaysTouchesBegan`,
    /// so brief light grazing taps (`10-25ms`) reach `keyCanvas.touchesBegan` immediately without lag or drop.
    private func disableTouchDelayOnContainerGestures() {
        var cur: UIView? = inputView ?? view
        while let v = cur {
            if let recognizers = v.gestureRecognizers {
                for gr in recognizers where gr.delaysTouchesBegan {
                    gr.delaysTouchesBegan = false
                }
            }
            cur = v.superview
        }
    }

    private var isDarkAppearance: Bool {
        (textDocumentProxy.keyboardAppearance == .dark)
            || (traitCollection.userInterfaceStyle == .dark)
    }

    private static func mapReturnKeyType(_ t: UIReturnKeyType?) -> IOSReturnKeyRole {
        guard let t else { return .normal }
        switch t {
        case .go: return .go
        case .google, .search, .yahoo: return .search
        case .send: return .send
        case .next: return .next
        case .done: return .done
        case .join: return .join
        case .continue: return .continueRole
        default: return .normal
        }
    }

    private static func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000.0)
    }
}
#endif
