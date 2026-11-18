#if os(iOS)
import UIKit

/// Reusable candidate button with subtle native rounded-pill highlight on touch-down.
@MainActor
private final class IOSRibbonSlotButton: UIButton {
    var slotIndex: Int = 0
    var starterWord: String?

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted
                ? UIColor.label.withAlphaComponent(0.10)
                : .clear
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 7.0
        layer.cornerCurve = .continuous
        var cfg = UIButton.Configuration.plain()
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 6)
        cfg.background.backgroundColor = .clear
        self.configuration = cfg
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// iOS 26 Native Airy Unboxed Candidate Bar (`44pt` height) with zero-allocation slot pooling:
/// - Zero view destruction/recreation during 120Hz typing bursts
/// - Clean `18pt` SF/PingFang text with tactile press highlight
final class IOSCandidateRibbonView: UIView {
    var onSelectCandidate: ((Int) -> Void)?
    var onSelectStarterWord: ((String) -> Void)?
    var onTapChevron: (() -> Void)?

    private let scrollView = UIScrollView()
    private let scrollMaskContainer = UIView()
    private let edgeFadeMask = CAGradientLayer()
    private let stackView = UIStackView()
    private let divider = UIView()
    private let chevronBtn = UIButton(type: .system)
    private var slotButtons: [IOSRibbonSlotButton] = []
    private var scrollTrailingToDivider: NSLayoutConstraint!
    private var scrollTrailingToFull: NSLayoutConstraint!

    private static let starterWords = ["我", "我们", "不是", "怎么", "你", "在", "这", "可以"]

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        scrollMaskContainer.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.spacing = 12
        stackView.alignment = .center
        scrollView.addSubview(stackView)
        scrollMaskContainer.addSubview(scrollView)

        edgeFadeMask.colors = [
            UIColor.black.cgColor,
            UIColor.black.cgColor,
            UIColor.clear.cgColor,
        ]
        edgeFadeMask.locations = [0.0, 0.92, 1.0]
        edgeFadeMask.startPoint = CGPoint(x: 0.0, y: 0.5)
        edgeFadeMask.endPoint = CGPoint(x: 1.0, y: 0.5)
        scrollMaskContainer.layer.mask = edgeFadeMask

        divider.translatesAutoresizingMaskIntoConstraints = false
        chevronBtn.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        chevronBtn.setImage(UIImage(systemName: "chevron.down", withConfiguration: cfg), for: .normal)
        chevronBtn.addTarget(self, action: #selector(handleChevron), for: .touchUpInside)

        addSubview(scrollMaskContainer)
        addSubview(divider)
        addSubview(chevronBtn)

        scrollTrailingToDivider = scrollMaskContainer.trailingAnchor.constraint(equalTo: divider.leadingAnchor)
        scrollTrailingToFull = scrollMaskContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)

        NSLayoutConstraint.activate([
            scrollMaskContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollTrailingToFull,
            scrollMaskContainer.topAnchor.constraint(equalTo: topAnchor),
            scrollMaskContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: scrollMaskContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: scrollMaskContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: scrollMaskContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: scrollMaskContainer.bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            stackView.centerYAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerYAnchor, constant: 1),

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

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeFadeMask.frame = scrollMaskContainer.bounds
        CATransaction.commit()
    }

    private func ensureSlotCapacity(_ count: Int) {
        while slotButtons.count < count {
            let btn = IOSRibbonSlotButton(type: .custom)
            btn.addTarget(self, action: #selector(handleSlotTap(_:)), for: .touchUpInside)
            btn.isHidden = true
            stackView.addArrangedSubview(btn)
            slotButtons.append(btn)
        }
    }

    @objc private func handleSlotTap(_ sender: IOSRibbonSlotButton) {
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
        scrollTrailingToDivider.isActive = !isEmpty
        scrollTrailingToFull.isActive = isEmpty

        UIView.performWithoutAnimation {
            if isEmpty {
                let words = Self.starterWords
                ensureSlotCapacity(words.count)
                for (i, btn) in slotButtons.enumerated() {
                    if i < words.count {
                        btn.slotIndex = i
                        btn.starterWord = words[i]
                        let attr = NSAttributedString(
                            string: words[i],
                            attributes: [
                                .font: UIFont.systemFont(ofSize: 18, weight: .regular),
                                .foregroundColor: textCol,
                            ]
                        )
                        btn.configuration?.attributedTitle = AttributedString(attr)
                        btn.isHidden = false
                    } else {
                        btn.isHidden = true
                    }
                }
            } else {
                let items = state.candidates
                ensureSlotCapacity(items.count)
                for (i, btn) in slotButtons.enumerated() {
                    if i < items.count {
                        let item = items[i]
                        btn.slotIndex = i
                        btn.starterWord = nil
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
                        btn.configuration?.attributedTitle = AttributedString(attr)
                        btn.isHidden = false
                    } else {
                        btn.isHidden = true
                    }
                }
            }
            scrollView.setContentOffset(.zero, animated: false)
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
