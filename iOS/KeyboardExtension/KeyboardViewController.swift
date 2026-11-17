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
        let isLandscape = view.bounds.width > 540
        // 44pt candidate ribbon + 219pt 4-row keyboard (`keyH = 45pt`) = 263pt matching iOS 26 native height
        let targetH: CGFloat = isLandscape ? 204 : 263
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
        inputView.clipsToBounds = false

        glassBackdrop.translatesAutoresizingMaskIntoConstraints = false
        glassBackdrop.layer.cornerRadius = IOSKeyboardLayoutEngine.trayTopCornerRadius
        glassBackdrop.layer.cornerCurve = .continuous
        glassBackdrop.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        glassBackdrop.layer.borderWidth = 0.5

        ribbonView.translatesAutoresizingMaskIntoConstraints = false
        ribbonView.accessibilityIdentifier = "PrisWubiRibbon"
        keyCanvas.translatesAutoresizingMaskIntoConstraints = false
        keyCanvas.accessibilityIdentifier = "PrisWubiKeyCanvas"
        expandedGrid.translatesAutoresizingMaskIntoConstraints = false
        quickPrefsView.translatesAutoresizingMaskIntoConstraints = false

        expandedGrid.isHidden = true
        quickPrefsView.isHidden = true
        calloutView.isHidden = true

        inputView.addSubview(glassBackdrop)
        inputView.addSubview(ribbonView)
        inputView.addSubview(keyCanvas)
        inputView.addSubview(expandedGrid)
        inputView.addSubview(quickPrefsView)
        inputView.addSubview(calloutView)

        let hc = inputView.heightAnchor.constraint(equalToConstant: 263)
        hc.priority = .defaultHigh
        self.heightConstraint = hc

        NSLayoutConstraint.activate([
            hc,
            glassBackdrop.topAnchor.constraint(equalTo: inputView.topAnchor),
            glassBackdrop.leadingAnchor.constraint(equalTo: inputView.leadingAnchor),
            glassBackdrop.trailingAnchor.constraint(equalTo: inputView.trailingAnchor),
            glassBackdrop.bottomAnchor.constraint(equalTo: inputView.bottomAnchor),

            ribbonView.topAnchor.constraint(equalTo: inputView.topAnchor),
            ribbonView.leadingAnchor.constraint(equalTo: inputView.leadingAnchor),
            ribbonView.trailingAnchor.constraint(equalTo: inputView.trailingAnchor),
            ribbonView.heightAnchor.constraint(equalToConstant: IOSKeyboardLayoutEngine.candidateBarHeight),

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
                self.lightHaptic.impactOccurred(intensity: 0.42)
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

        keyCanvas.onModeKeyLongPress = { [weak self] in
            guard let self else { return }
            UIDevice.current.playInputClick()
            self.toggleQuickPrefs()
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

        ribbonView.onSelectStarterWord = { [weak self] word in
            guard let self else { return }
            UIDevice.current.playInputClick()
            self.textDocumentProxy.insertText(word)
        }

        ribbonView.onTapChevron = { [weak self] in
            guard let self else { return }
            UIDevice.current.playInputClick()
            if self.bridge.state.preedit.isEmpty {
                self.toggleQuickPrefs()
            } else {
                self.quickPrefsView.isHidden = true
                self.expandedGrid.isHidden.toggle()
                let isExp = !self.expandedGrid.isHidden
                self.keyCanvas.isHidden = isExp
                if isExp {
                    self.expandedGrid.reload(candidates: self.bridge.allCandidates(maxCount: 60), dark: self.isDarkAppearance)
                }
                self.ribbonView.setExpanded(isExp)
            }
        }

        expandedGrid.onSelectAbsCandidate = { [weak self] absIdx in
            guard let self else { return }
            UIDevice.current.playInputClick()
            self.expandedGrid.isHidden = true
            self.keyCanvas.isHidden = false
            self.ribbonView.setExpanded(false)
            let out = self.bridge.selectAbsCandidate(absIndex: absIdx, timestampMs: Self.nowMs())
            self.applyEngineState(out)
        }

        expandedGrid.onCollapse = { [weak self] in
            self?.expandedGrid.isHidden = true
            self?.keyCanvas.isHidden = false
            self?.ribbonView.setExpanded(false)
        }

        expandedGrid.onBackspace = { [weak self] in
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
            self?.bridge.clearComposition()
            self?.clearMarkedTextSafely()
            self?.expandedGrid.isHidden = true
            self?.keyCanvas.isHidden = false
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
            self?.keyCanvas.isHidden = false
            self?.ribbonView.setExpanded(false)
        }
    }

    private func toggleQuickPrefs() {
        expandedGrid.isHidden = true
        quickPrefsView.isHidden.toggle()
        let open = !quickPrefsView.isHidden
        keyCanvas.isHidden = open
        ribbonView.setExpanded(open)
        if open {
            quickPrefsView.configure(prefs: bridge.prefs, dark: isDarkAppearance)
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

    private func clearMarkedTextSafely() {
        // In UIKit's UITextDocumentProxy, bare `unmarkText()` commits the marked string in place!
        // Setting empty marked text first removes the inline raw preedit before unmarking.
        textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        textDocumentProxy.unmarkText()
    }

    private func commitPendingFirstIfComposing() {
        guard !bridge.state.preedit.isEmpty else { return }
        clearMarkedTextSafely()
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
            clearMarkedTextSafely()
            textDocumentProxy.insertText(out.commitText)
            bridge.flushUserDataIfNeeded()
        }
        // Inline marked text directly in the iOS input field matching native Wubi!
        if out.preedit.isEmpty {
            if out.commitText.isEmpty {
                clearMarkedTextSafely()
            }
            if !expandedGrid.isHidden {
                expandedGrid.isHidden = true
                keyCanvas.isHidden = false
                ribbonView.setExpanded(false)
            }
        } else {
            textDocumentProxy.setMarkedText(
                out.preedit,
                selectedRange: NSRange(location: out.preedit.utf16.count, length: 0)
            )
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
        layoutEngine.showInlineGlobeKey = self.needsInputModeSwitchKey
        layoutEngine.returnRole = Self.mapReturnKeyType(textDocumentProxy.returnKeyType)
        let dark = isDarkAppearance

        // Keep backdrop completely transparent so iOS 26's native system Liquid Glass vibrancy shines through!
        glassBackdrop.backgroundColor = .clear
        glassBackdrop.layer.borderWidth = 0

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
