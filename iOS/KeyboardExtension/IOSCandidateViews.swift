#if os(iOS)
import UIKit

/// Direct `UIControl` + `UILabel` candidate slot (zero `UIButton.Configuration` deferred layout pass).
@MainActor
private final class IOSRibbonSlotControl: UIControl {
    var slotIndex: Int = 0
    var starterWord: String?
    private(set) var slotWidth: CGFloat = 0
    private let label = UILabel()

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted
                ? UIColor.label.withAlphaComponent(0.10)
                : .clear
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        layer.cornerRadius = 8.0
        layer.cornerCurve = .continuous

        label.numberOfLines = 1
        label.textAlignment = .center
        label.lineBreakMode = .byClipping
        label.isUserInteractionEnabled = false
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setRibbonTitle(_ title: NSAttributedString) {
        label.attributedText = title
        slotWidth = ceil(title.size().width) + 16.0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
    }
}

/// iOS 26 Native Airy Unboxed Candidate Bar (`44pt` height):
/// - Pure `UIView` horizontal track (`clipContainer` + `contentTrack` + horizontal `UIPanGestureRecognizer`)
///   with ZERO `UIScrollView`, completely eliminating iOS 26's `_UIScrollPocket` / `UIScrollEdgeEffect`
///   variable blur across the 44pt bar on physical devices and removing `UIScrollView` touch delay.
/// - Passes touches in the bottom `6pt` empty strip (`y = 38..44`) directly through to Row 0 (`q..p`).
final class IOSCandidateRibbonView: UIView, UIGestureRecognizerDelegate {
    var onSelectCandidate: ((Int) -> Void)?
    var onSelectStarterWord: ((String) -> Void)?
    var onTapChevron: (() -> Void)?

    private let clipContainer = UIView()
    private let contentTrack = UIView()
    private let edgeFadeMask = CAGradientLayer()
    private let divider = UIView()
    private let chevronBtn = UIButton(type: .system)
    private var slotControls: [IOSRibbonSlotControl] = []

    private var clipTrailingToDivider: NSLayoutConstraint!
    private var clipTrailingToFull: NSLayoutConstraint!

    private var contentWidth: CGFloat = 0
    private var scrollOffsetX: CGFloat = 0
    private var panStartOffsetX: CGFloat = 0

    private static let starterWords = ["我", "我们", "不是", "怎么", "你", "在", "这", "可以"]

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Pass touches in the bottom `7pt` strip (`y = 37..44`, below candidate glyphs) and in the lower half
    /// (`y = 20..44`) of unoccupied trailing candidate-bar space straight through to Row 0 (`q..p`),
    /// while preserving full `0..44pt` hit area on `chevronBtn` and eliminating inter-slot dead gaps.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard bounds.contains(point) else { return false }
        if !chevronBtn.isHidden && point.x >= divider.frame.minX - 4.0 {
            return true
        }
        if point.y > bounds.height - 7.0 {
            return false
        }
        let availW = clipContainer.bounds.width
        let hasScrollableOverflow = contentWidth > availW + 2.0
        if !hasScrollableOverflow {
            let maxVisibleMaxX = slotControls
                .lazy
                .filter { !$0.isHidden }
                .map { $0.frame.maxX - self.scrollOffsetX }
                .max() ?? 0
            if point.x > maxVisibleMaxX + 10.0 && point.y >= 20.0 {
                return false
            }
        }
        return true
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        if hit === clipContainer || hit === contentTrack {
            let trackPt = convert(point, to: contentTrack)
            var nearestSlot: IOSRibbonSlotControl?
            var bestDx = CGFloat.greatestFiniteMagnitude
            for slot in slotControls where !slot.isHidden {
                let dx = max(slot.frame.minX - trackPt.x, 0, trackPt.x - slot.frame.maxX)
                if dx <= 8.0 && dx < bestDx {
                    bestDx = dx
                    nearestSlot = slot
                }
            }
            if let nearestSlot {
                return nearestSlot
            }
        }
        return hit
    }

    private func setupViews() {
        clipContainer.translatesAutoresizingMaskIntoConstraints = false
        clipContainer.clipsToBounds = true
        clipContainer.backgroundColor = .clear

        contentTrack.backgroundColor = .clear
        clipContainer.addSubview(contentTrack)

        edgeFadeMask.colors = [
            UIColor.black.cgColor,
            UIColor.black.cgColor,
            UIColor.clear.cgColor,
        ]
        edgeFadeMask.locations = [0.0, 0.91, 1.0]
        edgeFadeMask.startPoint = CGPoint(x: 0.0, y: 0.5)
        edgeFadeMask.endPoint = CGPoint(x: 1.0, y: 0.5)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleHorizontalPan(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = true
        clipContainer.addGestureRecognizer(pan)

        divider.translatesAutoresizingMaskIntoConstraints = false
        chevronBtn.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        chevronBtn.setImage(UIImage(systemName: "chevron.down", withConfiguration: cfg), for: .normal)
        chevronBtn.addTarget(self, action: #selector(handleChevron), for: .touchUpInside)

        addSubview(clipContainer)
        addSubview(divider)
        addSubview(chevronBtn)

        clipTrailingToDivider = clipContainer.trailingAnchor.constraint(equalTo: divider.leadingAnchor)
        clipTrailingToFull = clipContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)

        NSLayoutConstraint.activate([
            clipContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            clipTrailingToFull,
            clipContainer.topAnchor.constraint(equalTo: topAnchor),
            clipContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            divider.trailingAnchor.constraint(equalTo: chevronBtn.leadingAnchor),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            divider.widthAnchor.constraint(equalToConstant: 0.65),
            divider.heightAnchor.constraint(equalToConstant: 20),

            chevronBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            chevronBtn.topAnchor.constraint(equalTo: topAnchor),
            chevronBtn.bottomAnchor.constraint(equalTo: bottomAnchor),
            chevronBtn.widthAnchor.constraint(equalToConstant: 44),
        ])

        ensureSlotCapacity(10)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard contentWidth > clipContainer.bounds.width + 2.0 else { return false }
        let vel = pan.velocity(in: clipContainer)
        return abs(vel.x) > abs(vel.y) * 1.2
    }

    @objc private func handleHorizontalPan(_ pan: UIPanGestureRecognizer) {
        let maxOffset = max(0, contentWidth - clipContainer.bounds.width)
        guard maxOffset > 0 else { return }

        switch pan.state {
        case .began:
            contentTrack.layer.removeAllAnimations()
            panStartOffsetX = scrollOffsetX
        case .changed:
            let dx = pan.translation(in: clipContainer).x
            let raw = panStartOffsetX - dx
            if raw < 0 {
                scrollOffsetX = raw * 0.25
            } else if raw > maxOffset {
                scrollOffsetX = maxOffset + (raw - maxOffset) * 0.25
            } else {
                scrollOffsetX = raw
            }
            applyScrollOffset()
        case .ended, .cancelled:
            let vx = pan.velocity(in: clipContainer).x
            let projected = min(max(0, scrollOffsetX - vx * 0.16), maxOffset)
            UIView.animate(
                withDuration: 0.24,
                delay: 0,
                options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState],
                animations: {
                    self.scrollOffsetX = projected
                    self.applyScrollOffset()
                }
            )
        default:
            break
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let barH = clipContainer.bounds.height
        let slotH = max(28.0, barH - 9.0)
        let slotY = floor((barH - slotH) * 0.5) + 0.5

        // Adaptive spacing when idle starter words slightly exceed narrower screens (e.g. 393/402pt)
        let visibleSlots = slotControls.filter { !$0.isHidden }
        let totalSlotWidths = visibleSlots.reduce(CGFloat(0)) { $0 + $1.slotWidth }
        let availW = clipContainer.bounds.width
        let spacing: CGFloat
        if lastPreeditEmpty == true, visibleSlots.count > 1, availW > 200 {
            let naturalSpan = 10.0 + totalSlotWidths + CGFloat(visibleSlots.count - 1) * 8.0 + 10.0
            if naturalSpan <= availW {
                spacing = min(14.0, floor((availW - 20.0 - totalSlotWidths) / CGFloat(visibleSlots.count - 1)))
            } else {
                spacing = 6.0
            }
        } else {
            spacing = 8.0
        }

        var x: CGFloat = 10.0
        for slot in visibleSlots {
            slot.frame = CGRect(x: x, y: slotY, width: slot.slotWidth, height: slotH)
            x = slot.frame.maxX + spacing
        }
        contentWidth = max(0, x - spacing + 10.0)

        let maxOffset = max(0, contentWidth - availW)
        if scrollOffsetX > maxOffset {
            scrollOffsetX = maxOffset
        }
        applyScrollOffset()
    }

    private func applyScrollOffset() {
        let barH = clipContainer.bounds.height
        let availW = clipContainer.bounds.width
        contentTrack.frame = CGRect(
            x: -scrollOffsetX,
            y: 0,
            width: max(availW, contentWidth),
            height: barH
        )
        // Only attach an alpha-fade mask when right-side content actually overflows:
        // avoids unnecessary Core Animation offscreen group rendering on normal/idle frames!
        let hasRightOverflow = (contentWidth - scrollOffsetX) > availW + 2.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hasRightOverflow {
            edgeFadeMask.frame = clipContainer.bounds
            if clipContainer.layer.mask !== edgeFadeMask {
                clipContainer.layer.mask = edgeFadeMask
            }
        } else if clipContainer.layer.mask != nil {
            clipContainer.layer.mask = nil
        }
        CATransaction.commit()
    }

    private func ensureSlotCapacity(_ count: Int) {
        while slotControls.count < count {
            let ctrl = IOSRibbonSlotControl(frame: .zero)
            ctrl.addTarget(self, action: #selector(handleSlotTap(_:)), for: .touchUpInside)
            ctrl.isHidden = true
            contentTrack.addSubview(ctrl)
            slotControls.append(ctrl)
        }
    }

    @objc private func handleSlotTap(_ sender: IOSRibbonSlotControl) {
        if let starter = sender.starterWord {
            onSelectStarterWord?(starter)
        } else {
            onSelectCandidate?(sender.slotIndex)
        }
    }

    func setExpanded(_ expanded: Bool) {
        let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        chevronBtn.setImage(
            UIImage(systemName: expanded ? "chevron.up" : "chevron.down", withConfiguration: cfg),
            for: .normal
        )
    }

    private var lastCandidates: [WubiCandidateItem]?
    private var lastPreeditEmpty: Bool?
    private var lastDark: Bool?

    func update(state: WubiActionState, dark: Bool) {
        let isEmpty = state.preedit.isEmpty
        if lastPreeditEmpty == isEmpty,
           lastDark == dark,
           (isEmpty || lastCandidates == state.candidates) {
            return
        }
        lastPreeditEmpty = isEmpty
        lastDark = dark
        lastCandidates = state.candidates

        let textCol: UIColor = dark ? .white : .black
        let subtleCol: UIColor = dark ? UIColor(white: 0.64, alpha: 1.0) : UIColor(white: 0.44, alpha: 1.0)
        divider.backgroundColor = (dark ? UIColor.white : UIColor.black).withAlphaComponent(0.14)
        chevronBtn.tintColor = textCol
        chevronBtn.isHidden = isEmpty
        divider.isHidden = isEmpty
        clipTrailingToDivider.isActive = !isEmpty
        clipTrailingToFull.isActive = isEmpty

        UIView.performWithoutAnimation {
            if isEmpty {
                let words = Self.starterWords
                ensureSlotCapacity(words.count)
                for (i, ctrl) in slotControls.enumerated() {
                    if i < words.count {
                        ctrl.slotIndex = i
                        ctrl.starterWord = words[i]
                        let attr = NSAttributedString(
                            string: words[i],
                            attributes: [
                                .font: UIFont.systemFont(ofSize: 18, weight: .regular),
                                .foregroundColor: textCol,
                            ]
                        )
                        ctrl.setRibbonTitle(attr)
                        ctrl.isHidden = false
                    } else {
                        ctrl.isHidden = true
                    }
                }
            } else {
                let items = state.candidates
                ensureSlotCapacity(items.count)
                for (i, ctrl) in slotControls.enumerated() {
                    if i < items.count {
                        let item = items[i]
                        ctrl.slotIndex = i
                        ctrl.starterWord = nil
                        let attr = NSMutableAttributedString(
                            string: item.text,
                            attributes: [
                                .font: UIFont.systemFont(ofSize: 18.5, weight: i == 0 ? .medium : .regular),
                                .foregroundColor: textCol,
                            ]
                        )
                        if !item.comment.isEmpty && (item.badgeKind == .typoCorrected || item.badgeKind == .pinyinLookup || item.badgeKind == .shortcode) {
                            let cleanHint = item.badgeKind == .typoCorrected
                                ? item.comment.components(separatedBy: " ").first ?? item.comment
                                : item.comment
                            attr.append(
                                NSAttributedString(
                                    string: " \(cleanHint)",
                                    attributes: [
                                        .font: UIFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
                                        .foregroundColor: subtleCol,
                                    ]
                                )
                            )
                        }
                        ctrl.setRibbonTitle(attr)
                        ctrl.isHidden = false
                    } else {
                        ctrl.isHidden = true
                    }
                }
            }
            scrollOffsetX = 0
            setNeedsLayout()
            layoutIfNeeded()
        }
    }

    @objc private func handleChevron() {
        onTapChevron?()
    }
}

/// Full-keyboard 4-column scrollable Expanded Candidate Grid matching iOS 26 continuous squircle keycap aesthetic.
final class IOSExpandedCandidateView: UIView {
    var onSelectAbsCandidate: ((Int) -> Void)?
    var onCollapse: (() -> Void)?
    var onBackspace: (() -> Void)?
    var onClear: (() -> Void)?

    private let scrollView = UIScrollView()
    private let gridStack = UIStackView()
    private let railStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 26.0, *) {
            scrollView.topEdgeEffect.isHidden = true
            scrollView.bottomEdgeEffect.isHidden = true
            scrollView.leftEdgeEffect.isHidden = true
            scrollView.rightEdgeEffect.isHidden = true
        }

        gridStack.translatesAutoresizingMaskIntoConstraints = false
        gridStack.axis = .vertical
        gridStack.spacing = 8

        railStack.translatesAutoresizingMaskIntoConstraints = false
        railStack.axis = .vertical
        railStack.distribution = .fillEqually
        railStack.spacing = 8

        scrollView.addSubview(gridStack)
        addSubview(scrollView)
        addSubview(railStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            scrollView.trailingAnchor.constraint(equalTo: railStack.leadingAnchor, constant: -8),

            gridStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            gridStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            gridStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            gridStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            gridStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            railStack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            railStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            railStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            railStack.widthAnchor.constraint(equalToConstant: 50),
        ])

        let collapseBtn = makeRailButton(title: nil, symbol: "chevron.up") { [weak self] in self?.onCollapse?() }
        let delBtn = makeRailButton(title: nil, symbol: "delete.backward") { [weak self] in self?.onBackspace?() }
        let clrBtn = makeRailButton(title: "重输", symbol: nil) { [weak self] in self?.onClear?() }
        railStack.addArrangedSubview(collapseBtn)
        railStack.addArrangedSubview(delBtn)
        railStack.addArrangedSubview(clrBtn)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reload(candidates: [WubiCandidateItem], dark: Bool) {
        backgroundColor = .clear
        let cellBg = dark ? UIColor(red: 0.28, green: 0.28, blue: 0.30, alpha: 1.0) : UIColor.white
        let textCol = dark ? UIColor.white : UIColor.black

        for case let btn as UIButton in railStack.arrangedSubviews {
            btn.backgroundColor = cellBg
            btn.tintColor = textCol
            btn.setTitleColor(textCol, for: .normal)
            btn.layer.shadowColor = UIColor.black.cgColor
            btn.layer.shadowOffset = CGSize(width: 0, height: 0.8)
            btn.layer.shadowRadius = 0.6
            btn.layer.shadowOpacity = dark ? 0.30 : 0.12
        }

        gridStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let cols = 4
        var idx = 0
        while idx < candidates.count {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 7
            for c in 0..<cols {
                if idx + c < candidates.count {
                    let item = candidates[idx + c]
                    let absIdx = idx + c
                    let btn = UIButton(type: .system)
                    btn.backgroundColor = cellBg
                    btn.layer.cornerRadius = 8.5
                    btn.layer.cornerCurve = .continuous
                    btn.layer.shadowColor = UIColor.black.cgColor
                    btn.layer.shadowOffset = CGSize(width: 0, height: 0.8)
                    btn.layer.shadowRadius = 0.6
                    btn.layer.shadowOpacity = dark ? 0.30 : 0.12
                    btn.setTitle(item.text, for: .normal)
                    btn.setTitleColor(textCol, for: .normal)
                    btn.titleLabel?.font = .systemFont(ofSize: 17, weight: .regular)
                    btn.heightAnchor.constraint(equalToConstant: 44).isActive = true
                    btn.addAction(UIAction { [weak self] _ in self?.onSelectAbsCandidate?(absIdx) }, for: .touchUpInside)
                    row.addArrangedSubview(btn)
                } else {
                    row.addArrangedSubview(UIView())
                }
            }
            gridStack.addArrangedSubview(row)
            idx += cols
        }
    }

    private func makeRailButton(title: String?, symbol: String?, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.layer.cornerRadius = 8.5
        b.layer.cornerCurve = .continuous
        if let s = symbol {
            b.setImage(UIImage(systemName: s), for: .normal)
        } else {
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 14, weight: .regular)
        }
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }
}
#endif
