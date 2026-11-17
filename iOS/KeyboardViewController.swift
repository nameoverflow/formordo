#if os(iOS)
import UIKit

/// Native iOS Keyboard Extension (`UIInputViewController`) powered by the shared Rust `wubi-core` engine.
///
/// Key architectural traits:
/// 1. Zero-copy `mmap` loading of `wubi86.wbdict` / `wubi98.wbdict` / `wubi06.wbdict` + `wubi_aux.wbaux`
///    keeps Keyboard Extension Dirty RSS well under iOS's strict ~50 MB jetsam limit.
/// 2. Continuous 2D touch coordinates (`UITouch.location(in: keyboardCanvas)`) feed directly into
///    `wubi_engine_push_touch_json` for Gaussian soft-Voronoi hitbox + N-gram confidence typo rescue
///    and online per-key thumb drift EMA adaptation.
/// 3. Works 100% offline WITHOUT requiring "Allow Full Access" (`UIInputViewAudioFeedback` provides
///    native system key clicks; optional App Group container sync activates automatically if granted).
public final class KeyboardViewController: UIInputViewController {
    private var engineHandle: OpaquePointer?
    private let candidateBar = CandidateStripView()
    private let keyCanvas = NativeKeyCanvasView()
    private let calloutBubble = KeyCalloutBubbleView()

    private var currentCandidates: [WubiCandidateItem] = []
    private var currentPreedit: String = ""
    private var currentSchemaId: UInt32 = 86

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupEngine()
        setupHierarchy()
    }

    deinit {
        if let h = engineHandle {
            wubi_engine_free(h)
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        keyCanvas.recomputeGeometry()
        syncKeyCentersToCore()
    }

    public override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
    }

    public override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        updateAppearance()
    }

    private func setupEngine() {
        let h = wubi_engine_new()
        self.engineHandle = h
        if let dictDir = Bundle.main.resourceURL?.appendingPathComponent("Dicts", isDirectory: true) {
            for (id, file) in [(UInt32(86), "wubi86.wbdict"), (98, "wubi98.wbdict"), (6, "wubi06.wbdict")] {
                let p = dictDir.appendingPathComponent(file).path
                _ = p.withCString { wubi_engine_load_dict_mmap(h, id, $0) }
            }
            let auxPath = dictDir.appendingPathComponent("wubi_aux.wbaux").path
            _ = auxPath.withCString { wubi_engine_load_aux_mmap(h, $0) }
        }

        // Load config & user data from App Group if accessible, else extension sandbox Documents
        let storageDir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.priswubi.shared")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let dir = storageDir {
            let cfg = dir.appendingPathComponent("config.toml").path
            _ = cfg.withCString { wubi_engine_load_config(h, $0) }
            let usr = dir.appendingPathComponent("user_data.tsv").path
            _ = usr.withCString { wubi_engine_load_user_data(h, $0) }
        }
        currentSchemaId = wubi_engine_get_schema(h)
    }

    private func syncKeyCentersToCore() {
        guard let h = engineHandle else { return }
        var centers52 = [Float](repeating: 0, count: 52)
        for i in 0..<26 {
            let ch = UInt8(ascii: "a") + UInt8(i)
            let pt = keyCanvas.normalizedCenter(for: ch)
            centers52[i * 2] = Float(pt.x)
            centers52[i * 2 + 1] = Float(pt.y)
        }
        let geom = keyCanvas.pitchTransform
        centers52.withUnsafeBufferPointer { buf in
            wubi_engine_set_key_layout(
                h,
                buf.baseAddress,
                Float(geom.originX),
                Float(geom.originY),
                Float(geom.pitchX),
                Float(geom.pitchY)
            )
        }
    }

    private func setupHierarchy() {
        guard let inputView = self.inputView else { return }
        inputView.allowsSelfSizing = true

        candidateBar.translatesAutoresizingMaskIntoConstraints = false
        keyCanvas.translatesAutoresizingMaskIntoConstraints = false
        calloutBubble.isHidden = true

        inputView.addSubview(candidateBar)
        inputView.addSubview(keyCanvas)
        inputView.addSubview(calloutBubble)

        NSLayoutConstraint.activate([
            candidateBar.topAnchor.constraint(equalTo: inputView.topAnchor),
            candidateBar.leadingAnchor.constraint(equalTo: inputView.leadingAnchor),
            candidateBar.trailingAnchor.constraint(equalTo: inputView.trailingAnchor),
            candidateBar.heightAnchor.constraint(equalToConstant: 42),

            keyCanvas.topAnchor.constraint(equalTo: candidateBar.bottomAnchor),
            keyCanvas.leadingAnchor.constraint(equalTo: inputView.leadingAnchor),
            keyCanvas.trailingAnchor.constraint(equalTo: inputView.trailingAnchor),
            keyCanvas.bottomAnchor.constraint(equalTo: inputView.bottomAnchor),
            keyCanvas.heightAnchor.constraint(equalToConstant: 216),
        ])

        keyCanvas.showGlobeKey = self.needsInputModeSwitchKey
        keyCanvas.onLetterTouchDown = { [weak self] ch, keyFrame in
            UIDevice.current.playInputClick()
            self?.calloutBubble.present(letter: String(UnicodeScalar(ch)).uppercased(), over: keyFrame)
        }
        keyCanvas.onLetterTouchUp = { [weak self] ch, rawPoint in
            self?.calloutBubble.isHidden = true
            self?.handleTouchLetter(ch: ch, point: rawPoint)
        }
        keyCanvas.onSpecialAction = { [weak self] action in
            UIDevice.current.playInputClick()
            self?.handleSpecialKey(action)
        }
        keyCanvas.onNextInputMode = { [weak self] in
            self?.advanceToNextInputMode()
        }
        keyCanvas.onTrackpadCursorDelta = { [weak self] charOffset in
            self?.textDocumentProxy.adjustTextPosition(byCharacterOffset: charOffset)
        }

        candidateBar.onSelectCandidate = { [weak self] idx in
            UIDevice.current.playInputClick()
            self?.selectCandidate(at: idx)
        }
        candidateBar.onCycleSchema = { [weak self] in
            UIDevice.current.playInputClick()
            self?.cycleSchema()
        }
        updateAppearance()
    }

    private func handleTouchLetter(ch: UInt8, point: CGPoint) {
        guard let h = engineHandle else { return }
        let ts = UInt64(Date().timeIntervalSince1970 * 1000.0)
        let ptr = wubi_engine_push_touch_json(h, ch, Float(point.x), Float(point.y), false, ts)
        applyStateJSON(ptr)
    }

    private func handleSpecialKey(_ action: NativeKeyCanvasView.SpecialKey) {
        guard let h = engineHandle else { return }
        let ts = UInt64(Date().timeIntervalSince1970 * 1000.0)
        switch action {
        case .backspace:
            if currentPreedit.isEmpty {
                textDocumentProxy.deleteBackward()
            } else {
                let ptr = wubi_engine_handle_key_json(h, 0x33, 0, false, ts)
                applyStateJSON(ptr)
            }
        case .space:
            if currentPreedit.isEmpty {
                textDocumentProxy.insertText(" ")
            } else {
                let ptr = wubi_engine_handle_key_json(h, 0x31, 32, false, ts)
                applyStateJSON(ptr)
            }
        case .returnKey:
            if currentPreedit.isEmpty {
                textDocumentProxy.insertText("\n")
            } else {
                let ptr = wubi_engine_handle_key_json(h, 0x24, 13, false, ts)
                applyStateJSON(ptr)
            }
        case .shiftToggle:
            let ptr = wubi_engine_toggle_ascii_json(h)
            applyStateJSON(ptr)
        }
    }

    private func selectCandidate(at idx: Int) {
        guard let h = engineHandle else { return }
        let ts = UInt64(Date().timeIntervalSince1970 * 1000.0)
        let ptr = wubi_engine_select_candidate_json(h, UInt32(idx), ts)
        applyStateJSON(ptr)
    }

    private func cycleSchema() {
        guard let h = engineHandle else { return }
        let next: UInt32 = (currentSchemaId == 86) ? 98 : ((currentSchemaId == 98) ? 6 : 86)
        wubi_engine_set_schema(h, next)
        currentSchemaId = next
        candidateBar.update(preedit: "", schemaId: next, candidates: [])
    }

    private func applyStateJSON(_ rawPtr: UnsafeMutablePointer<CChar>?) {
        guard let rawPtr else { return }
        defer { wubi_string_free(rawPtr) }
        let json = String(cString: rawPtr)
        guard let data = json.data(using: .utf8),
              let state = try? JSONDecoder().decode(WubiActionState.self, from: data) else {
            return
        }
        if !state.commitText.isEmpty {
            textDocumentProxy.insertText(state.commitText)
        }
        self.currentPreedit = state.preedit
        self.currentCandidates = state.candidates
        self.currentSchemaId = state.schemaId
        candidateBar.update(
            preedit: state.preedit,
            schemaId: state.schemaId,
            candidates: state.candidates
        )
    }

    private func updateAppearance() {
        let isDark = (textDocumentProxy.keyboardAppearance == .dark)
            || (traitCollection.userInterfaceStyle == .dark)
        keyCanvas.applyTheme(dark: isDark)
        candidateBar.applyTheme(dark: isDark)
    }
}

/// System click-sound compliant keyboard canvas with continuous touch coordinates & spacebar trackpad.
final class NativeKeyCanvasView: UIInputView, UIInputViewAudioFeedback {
    enum SpecialKey {
        case backspace
        case space
        case returnKey
        case shiftToggle
    }

    var enableInputClicksWhenVisible: Bool { true }
    var showGlobeKey: Bool = true

    var onLetterTouchDown: ((UInt8, CGRect) -> Void)?
    var onLetterTouchUp: ((UInt8, CGPoint) -> Void)?
    var onSpecialAction: ((SpecialKey) -> Void)?
    var onNextInputMode: (() -> Void)?
    var onTrackpadCursorDelta: ((Int) -> Void)?

    private(set) var pitchTransform: (originX: CGFloat, originY: CGFloat, pitchX: CGFloat, pitchY: CGFloat) = (0, 0, 1, 1)
    private var letterFrames: [UInt8: CGRect] = [:]
    private var isDarkTheme = false
    private var spaceTrackpadLastX: CGFloat?

    init() {
        super.init(frame: .zero, inputViewStyle: .keyboard)
        isMultipleTouchEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(dark: Bool) {
        isDarkTheme = dark
        setNeedsDisplay()
    }

    func normalizedCenter(for key: UInt8) -> CGPoint {
        guard let f = letterFrames[key], pitchTransform.pitchX > 0, pitchTransform.pitchY > 0 else {
            return .zero
        }
        return CGPoint(
            x: (f.midX - pitchTransform.originX) / pitchTransform.pitchX,
            y: (f.midY - pitchTransform.originY) / pitchTransform.pitchY
        )
    }

    func recomputeGeometry() {
        letterFrames.removeAll()
        let w = bounds.width
        guard w > 10 else { return }
        let hPad: CGFloat = 3
        let pitchX = (w - hPad * 2) / 10.0
        let pitchY: CGFloat = 54
        let keyH: CGFloat = 42
        let topY: CGFloat = 8

        let rows: [(String, CGFloat)] = [
            ("qwertyuiop", 0.0),
            ("asdfghjkl", 0.5),
            ("zxcvbnm", 1.5),
        ]
        for (r, (chars, indent)) in rows.enumerated() {
            for (c, ch) in chars.utf8.enumerated() {
                let cx = hPad + (CGFloat(c) + indent + 0.5) * pitchX
                let cy = topY + CGFloat(r) * pitchY + keyH * 0.5
                letterFrames[ch] = CGRect(
                    x: cx - (pitchX - 6) * 0.5,
                    y: cy - keyH * 0.5,
                    width: pitchX - 6,
                    height: keyH
                )
            }
        }
        if let qRect = letterFrames[UInt8(ascii: "q")] {
            pitchTransform = (qRect.midX, qRect.midY, pitchX, pitchY)
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        let keyFill = isDarkTheme
            ? UIColor(white: 0.42, alpha: 1.0)
            : UIColor.white
        let textCol = isDarkTheme ? UIColor.white : UIColor.black

        for (ch, frame) in letterFrames {
            let path = UIBezierPath(roundedRect: frame, cornerRadius: 5.0)
            UIColor.black.withAlphaComponent(0.28).setFill()
            path.apply(CGAffineTransform(translationX: 0, y: 1))
            path.fill()

            let mainPath = UIBezierPath(roundedRect: frame, cornerRadius: 5.0)
            keyFill.setFill()
            mainPath.fill()

            let s = String(UnicodeScalar(ch)).uppercased() as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .regular),
                .foregroundColor: textCol,
            ]
            let sz = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: frame.midX - sz.width * 0.5, y: frame.midY - sz.height * 0.5), withAttributes: attrs)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let pt = touches.first?.location(in: self) else { return }
        if pt.y < 162, let (ch, frame) = nearestLetter(to: pt) {
            onLetterTouchDown?(ch, frame)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let pt = touch.location(in: self)
        // Long-press / drag on bottom spacebar row acts as native iOS cursor trackpad!
        if pt.y >= 162 {
            if let prevX = spaceTrackpadLastX {
                let dx = pt.x - prevX
                if abs(dx) >= 9.0 {
                    onTrackpadCursorDelta?(dx > 0 ? 1 : -1)
                    spaceTrackpadLastX = pt.x
                }
            } else if touch.force > 1.5 || touch.timestamp > 0 {
                spaceTrackpadLastX = pt.x
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { spaceTrackpadLastX = nil }
        guard let pt = touches.first?.location(in: self) else { return }
        if pt.y < 162, let (ch, _) = nearestLetter(to: pt) {
            // Pass exact continuous touch point `pt` to wubi-core!
            onLetterTouchUp?(ch, pt)
        } else {
            // Bottom control row
            let ratio = pt.x / max(1, bounds.width)
            if ratio < 0.14 {
                onSpecialAction?(.shiftToggle)
            } else if ratio < 0.26 && showGlobeKey {
                onNextInputMode?()
            } else if ratio < 0.74 {
                onSpecialAction?(.space)
            } else if ratio < 0.88 {
                onSpecialAction?(.backspace)
            } else {
                onSpecialAction?(.returnKey)
            }
        }
    }

    private func nearestLetter(to pt: CGPoint) -> (UInt8, CGRect)? {
        var best: (UInt8, CGRect)?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (ch, frame) in letterFrames {
            let d = hypot(pt.x - frame.midX, pt.y - frame.midY)
            if d < bestDist {
                bestDist = d
                best = (ch, frame)
            }
        }
        return best
    }
}

final class CandidateStripView: UIView {
    var onSelectCandidate: ((Int) -> Void)?
    var onCycleSchema: (() -> Void)?

    private let schemaButton = UIButton(type: .system)
    private let preeditLabel = UILabel()
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        schemaButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        schemaButton.layer.cornerRadius = 6
        schemaButton.addTarget(self, action: #selector(handleSchemaTap), for: .touchUpInside)

        preeditLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        stackView.axis = .horizontal
        stackView.spacing = 8

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.addSubview(stackView)
        addSubview(schemaButton)
        addSubview(preeditLabel)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleSchemaTap() {
        onCycleSchema?()
    }

    func applyTheme(dark: Bool) {
        preeditLabel.textColor = dark ? .white : .black
        schemaButton.backgroundColor = (dark ? UIColor.white : UIColor.black).withAlphaComponent(0.1)
    }

    func update(preedit: String, schemaId: UInt32, candidates: [WubiCandidateItem]) {
        let tag = (schemaId == 98) ? "98五笔" : ((schemaId == 6) ? "新世纪" : "86五笔")
        schemaButton.setTitle(tag, for: .normal)
        preeditLabel.text = preedit

        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (idx, item) in candidates.enumerated() {
            let btn = UIButton(type: .system)
            let title = item.comment.isEmpty ? item.text : "\(item.text) \(item.comment)"
            btn.setTitle(title, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 16, weight: idx == 0 ? .semibold : .regular)
            btn.tag = idx
            btn.addTarget(self, action: #selector(handleCandTap(_:)), for: .touchUpInside)
            stackView.addArrangedSubview(btn)
        }
    }

    @objc private func handleCandTap(_ sender: UIButton) {
        onSelectCandidate?(sender.tag)
    }
}

final class KeyCalloutBubbleView: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 46, height: 56))
        backgroundColor = .white
        layer.cornerRadius = 8
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)

        label.font = .systemFont(ofSize: 28, weight: .regular)
        label.textAlignment = .center
        label.frame = bounds
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(letter: String, over keyFrame: CGRect) {
        label.text = letter
        center = CGPoint(x: keyFrame.midX, y: keyFrame.minY - 18)
        isHidden = false
    }
}
#endif
