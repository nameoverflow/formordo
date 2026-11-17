#if os(iOS)
import UIKit

@objc(KeyboardViewController)
public final class KeyboardViewController: UIInputViewController {
    private lazy var bridge = WubiBridge()
    private var layoutEngine = IOSKeyboardLayoutEngine()

    private let ribbonView = IOSCandidateRibbonView()
    private let keyCanvas = IOSKeyCanvasView()
    private let expandedGrid = IOSExpandedCandidateView()
    private let quickPrefsView = IOSQuickPrefsView()
    private let calloutView = IOSKeyCalloutView()

    private var heightConstraint: NSLayoutConstraint?
    private var backspaceTimer: Timer?
    private var backspaceHoldTicks: Int = 0
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let selectionHaptic = UISelectionFeedbackGenerator()

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        syncEngineToUI()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Reload shared App Group preferences if updated from Host App
        bridge.loadConfigAndUser()
        syncEngineToUI()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopBackspaceRepeat()
        bridge.flushUserDataIfNeeded()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let isLandscape = view.bounds.width > 520
        let targetH: CGFloat = isLandscape ? 204 : 260
        if heightConstraint?.constant != targetH {
            heightConstraint?.constant = targetH
        }
        refreshKeyboardLayout()
    }

    public override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        syncProxyTraits()
    }

    private func setupViews() {
        guard let inputView = self.inputView else { return }
        inputView.allowsSelfSizing = true

        ribbonView.translatesAutoresizingMaskIntoConstraints = false
        keyCanvas.translatesAutoresizingMaskIntoConstraints = false
        expandedGrid.translatesAutoresizingMaskIntoConstraints = false
        quickPrefsView.translatesAutoresizingMaskIntoConstraints = false

        expandedGrid.isHidden = true
        quickPrefsView.isHidden = true
        calloutView.isHidden = true

        inputView.addSubview(ribbonView)
        inputView.addSubview(keyCanvas)
        inputView.addSubview(expandedGrid)
        inputView.addSubview(quickPrefsView)
        inputView.addSubview(calloutView)

        let hc = inputView.heightAnchor.constraint(equalToConstant: 260)
        hc.priority = .defaultHigh
        self.heightConstraint = hc

        NSLayoutConstraint.activate([
            hc,
            ribbonView.topAnchor.constraint(equalTo: inputView.topAnchor),
            ribbonView.leadingAnchor.constraint(equalTo: inputView.leadingAnchor),
            ribbonView.trailingAnchor.constraint(equalTo: inputView.trailingAnchor),
            ribbonView.heightAnchor.constraint(equalToConstant: 44),

            keyCanvas.topAnchor.constraint(equalTo: ribbonView.bottomAnchor),
            keyCanvas.leadingAnchor.constraint(equalTo: inputView.leadingAnchor),
            keyCanvas.trailingAnchor.constraint(equalTo: inputView.trailingAnchor),
            keyCanvas.bottomAnchor.constraint(equalTo: inputView.bottomAnchor),

            expandedGrid.topAnchor.constraint(equalTo: ribbonView.bottomAnchor),
            expandedGrid.leadingAnchor.constraint(equalTo: inputView.leadingAnchor),
            expandedGrid.trailingAnchor.constraint(equalTo: inputView.trailingAnchor),
            expandedGrid.bottomAnchor.constraint(equalTo: inputView.bottomAnchor),

            quickPrefsView.topAnchor.constraint(equalTo: ribbonView.bottomAnchor),
            quickPrefsView.leadingAnchor.constraint(equalTo: inputView.leadingAnchor),
            quickPrefsView.trailingAnchor.constraint(equalTo: inputView.trailingAnchor),
            quickPrefsView.bottomAnchor.constraint(equalTo: inputView.bottomAnchor),
        ])

        wireCallbacks()
        syncProxyTraits()
    }

    private func wireCallbacks() {
        keyCanvas.onKeyTouchDown = { [weak self] spec in
            guard let self else { return }
            UIDevice.current.playInputClick()
            if self.bridge.hasSharedContainerAccess {
                self.lightHaptic.impactOccurred(intensity: 0.45)
            }
            switch spec.kind {
            case .letter:
                if !self.layoutEngine.isTrackpadActive {
                    let frameInRoot = self.keyCanvas.convert(spec.frame, to: self.inputView)
                    self.calloutView.present(label: spec.primaryLabel, over: frameInRoot, dark: self.isDarkAppearance)
                }
            case .backspace:
                self.performBackspace()
                self.startBackspaceRepeat()
            default:
                break
            }
        }

        keyCanvas.onKeyTouchCancel = { [weak self] in
            self?.calloutView.isHidden = true
            self?.stopBackspaceRepeat()
        }

        keyCanvas.onKeyTouchUp = { [weak self] spec, rawPointInCanvas in
            guard let self else { return }
            self.calloutView.isHidden = true
            self.stopBackspaceRepeat()
            self.handleKeyRelease(spec: spec, pointInCanvas: rawPointInCanvas)
        }

        keyCanvas.onTrackpadStateChanged = { [weak self] active in
            guard let self else { return }
            self.calloutView.isHidden = true
            self.layoutEngine.isTrackpadActive = active
            if active && self.bridge.hasSharedContainerAccess {
                self.selectionHaptic.selectionChanged()
            }
            self.refreshKeyboardLayout()
        }

        keyCanvas.onTrackpadStep = { [weak self] delta in
            guard let self else { return }
            if !self.bridge.state.preedit.isEmpty {
                return
            }
            self.textDocumentProxy.adjustTextPosition(byCharacterOffset: delta)
            if self.bridge.hasSharedContainerAccess {
                self.selectionHaptic.selectionChanged()
            }
        }

        ribbonView.onSelectCandidate = { [weak self] relIdx in
            guard let self else { return }
            UIDevice.current.playInputClick()
            let out = self.bridge.selectCandidate(pageRelIndex: relIdx, timestampMs: Self.nowMs())
            self.applyEngineState(out)
        }

        ribbonView.onToggleExpand = { [weak self] in
            guard let self else { return }
            UIDevice.current.playInputClick()
            self.quickPrefsView.isHidden = true
            self.expandedGrid.isHidden.toggle()
            if !self.expandedGrid.isHidden {
                self.expandedGrid.reload(candidates: self.bridge.allCandidates(maxCount: 60), dark: self.isDarkAppearance)
            }
            self.ribbonView.setExpanded(!self.expandedGrid.isHidden)
        }

        ribbonView.onCycleSchema = { [weak self] in
            guard let self else { return }
            UIDevice.current.playInputClick()
            let cur = self.bridge.prefs.schemaId
            let next: UInt32 = (cur == 86) ? 98 : ((cur == 98) ? 6 : 86)
            self.bridge.switchSchema(next)
            self.syncEngineToUI()
        }

        ribbonView.onToggleMode = { [weak self] in
            guard let self else { return }
            UIDevice.current.playInputClick()
            let out = self.bridge.toggleAsciiMode()
            self.applyEngineState(out)
        }

        ribbonView.onQuickPunctuation = { [weak self] punc in
            guard let self else { return }
            UIDevice.current.playInputClick()
            if punc == "“”" {
                self.textDocumentProxy.insertText("“”")
                self.textDocumentProxy.adjustTextPosition(byCharacterOffset: -1)
            } else {
                self.textDocumentProxy.insertText(punc)
            }
        }

        ribbonView.onToggleQuickPrefs = { [weak self] in
            guard let self else { return }
            UIDevice.current.playInputClick()
            self.expandedGrid.isHidden = true
            self.ribbonView.setExpanded(false)
            self.quickPrefsView.isHidden.toggle()
            if !self.quickPrefsView.isHidden {
                self.quickPrefsView.configure(prefs: self.bridge.prefs, dark: self.isDarkAppearance)
            }
        }

        expandedGrid.onSelectAbsCandidate = { [weak self] absIdx in
            guard let self else { return }
            UIDevice.current.playInputClick()
            self.expandedGrid.isHidden = true
            self.ribbonView.setExpanded(false)
            let out = self.bridge.selectAbsCandidate(absIndex: absIdx, timestampMs: Self.nowMs())
            self.applyEngineState(out)
        }

        expandedGrid.onCollapse = { [weak self] in
            self?.expandedGrid.isHidden = true
            self?.ribbonView.setExpanded(false)
        }

        expandedGrid.onBackspace = { [weak self] in
            self?.performBackspace()
            if let self, !self.expandedGrid.isHidden {
                if self.bridge.state.preedit.isEmpty {
                    self.expandedGrid.isHidden = true
                    self.ribbonView.setExpanded(false)
                } else {
                    self.expandedGrid.reload(candidates: self.bridge.allCandidates(maxCount: 60), dark: self.isDarkAppearance)
                }
            }
        }

        expandedGrid.onClear = { [weak self] in
            self?.bridge.clearComposition()
            self?.expandedGrid.isHidden = true
            self?.ribbonView.setExpanded(false)
            self?.syncEngineToUI()
        }

        quickPrefsView.onUpdatePrefs = { [weak self] updated in
            guard let self else { return }
            self.bridge.applyAndSavePreferences(updated)
            self.syncEngineToUI()
        }

        quickPrefsView.onClose = { [weak self] in
            self?.quickPrefsView.isHidden = true
        }
    }

    private func handleKeyRelease(spec: IOSKeySpec, pointInCanvas: CGPoint) {
        switch spec.kind {
        case .letter(let ascii):
            // English mode OR active Shift uppercase: commit pending candidate and insert letter directly
            if layoutEngine.asciiMode || layoutEngine.shiftState.isUppercase {
                commitPendingFirstIfComposing()
                let ch = String(UnicodeScalar(ascii))
                let outStr = layoutEngine.shiftState.isUppercase ? ch.uppercased() : ch.lowercased()
                textDocumentProxy.insertText(outStr)
                layoutEngine.consumeOneShotShiftIfNeeded()
                refreshKeyboardLayout()
            } else {
                // Chinese Wubi continuous touch-coordinate decoding!
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
            syncEngineToUI()

        case .shift:
            layoutEngine.tapShift(at: ProcessInfo.processInfo.systemUptime)
            refreshKeyboardLayout()

        case .backspace:
            // Handled immediately on touchDown + repeat timer
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
        bridge.clearComposition()
    }

    private func performBackspace() {
        if bridge.state.preedit.isEmpty {
            textDocumentProxy.deleteBackward()
        } else {
            let out = bridge.handleKey(keyCode: 0x33, scalar: 0, hasCmdOrCtrl: false, timestampMs: Self.nowMs())
            applyEngineState(out)
        }
    }

    private func startBackspaceRepeat() {
        stopBackspaceRepeat()
        backspaceHoldTicks = 0
        backspaceTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.backspaceHoldTicks += 1
                // Wait ~0.40s (5 ticks) before continuous repeat starts
                if self.backspaceHoldTicks >= 5 {
                    UIDevice.current.playInputClick()
                    self.performBackspace()
                }
            }
        }
    }

    private func stopBackspaceRepeat() {
        backspaceTimer?.invalidate()
        backspaceTimer = nil
        backspaceHoldTicks = 0
    }

    private func applyEngineState(_ out: WubiActionState) {
        if !out.commitText.isEmpty {
            textDocumentProxy.insertText(out.commitText)
            bridge.flushUserDataIfNeeded()
        }
        if out.preedit.isEmpty && !expandedGrid.isHidden {
            expandedGrid.isHidden = true
            ribbonView.setExpanded(false)
        }
        syncEngineToUI()
    }

    private func syncEngineToUI() {
        let st = bridge.state
        layoutEngine.asciiMode = st.asciiMode
        layoutEngine.schemaId = st.schemaId
        layoutEngine.isComposing = !st.preedit.isEmpty
        ribbonView.update(state: st, dark: isDarkAppearance)
        refreshKeyboardLayout()
    }

    private func syncProxyTraits() {
        layoutEngine.showGlobeKey = self.needsInputModeSwitchKey
        layoutEngine.returnRole = Self.mapReturnKeyType(textDocumentProxy.returnKeyType)
        let dark = isDarkAppearance
        keyCanvas.applyTheme(dark: dark)
        ribbonView.update(state: bridge.state, dark: dark)
        refreshKeyboardLayout()
    }

    private func refreshKeyboardLayout() {
        guard keyCanvas.bounds.width > 10, keyCanvas.bounds.height > 10 else { return }
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
