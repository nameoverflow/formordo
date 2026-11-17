#if os(iOS)
import UIKit

/// iOS 26 Native Airy Unboxed Candidate Bar (`52pt` height):
/// - Zero pill boxes around candidates: clean `18pt` PingFang SC Regular text with `22pt` spacing
/// - When idle (`preedit.isEmpty`), displays high-frequency starter words just like Apple native Wubi,
///   with a thin right-hand vertical hairline and `⌄` chevron (tapping `⌄` while idle opens quick settings)
final class IOSCandidateRibbonView: UIView {
    var onSelectCandidate: ((Int) -> Void)?
    var onSelectStarterWord: ((String) -> Void)?
    var onTapChevron: (() -> Void)?

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let divider = UIView()
    private let chevronBtn = UIButton(type: .system)

    private static let starterWords = ["我", "我们", "不是", "怎么", "你", "在", "这", "可以"]

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.spacing = 22
        stackView.alignment = .center
        scrollView.addSubview(stackView)

        divider.translatesAutoresizingMaskIntoConstraints = false
        chevronBtn.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        chevronBtn.setImage(UIImage(systemName: "chevron.down", withConfiguration: cfg), for: .normal)
        chevronBtn.addTarget(self, action: #selector(handleChevron), for: .touchUpInside)

        addSubview(scrollView)
        addSubview(divider)
        addSubview(chevronBtn)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 14),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -14),
            stackView.centerYAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerYAnchor, constant: 1),

            divider.trailingAnchor.constraint(equalTo: chevronBtn.leadingAnchor),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            divider.widthAnchor.constraint(equalToConstant: 0.7),
            divider.heightAnchor.constraint(equalToConstant: 21),

            chevronBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            chevronBtn.topAnchor.constraint(equalTo: topAnchor),
            chevronBtn.bottomAnchor.constraint(equalTo: bottomAnchor),
            chevronBtn.widthAnchor.constraint(equalToConstant: 44),
        ])
    }

    func setExpanded(_ expanded: Bool) {
        let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        chevronBtn.setImage(
            UIImage(systemName: expanded ? "chevron.up" : "chevron.down", withConfiguration: cfg),
            for: .normal
        )
    }

    func update(state: WubiActionState, dark: Bool) {
        let textCol: UIColor = dark ? .white : .black
        let subtleCol: UIColor = dark ? UIColor(white: 0.62, alpha: 1.0) : UIColor(white: 0.45, alpha: 1.0)
        divider.backgroundColor = (dark ? UIColor.white : UIColor.black).withAlphaComponent(0.14)
        chevronBtn.tintColor = textCol

        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if state.preedit.isEmpty {
            for word in Self.starterWords {
                let btn = UIButton(type: .system)
                btn.setTitle(word, for: .normal)
                btn.setTitleColor(textCol, for: .normal)
                btn.titleLabel?.font = .systemFont(ofSize: 18, weight: .regular)
                btn.addAction(UIAction { [weak self] _ in self?.onSelectStarterWord?(word) }, for: .touchUpInside)
                stackView.addArrangedSubview(btn)
            }
        } else {
            for (idx, item) in state.candidates.enumerated() {
                let btn = UIButton(type: .system)
                let attr = NSMutableAttributedString(
                    string: item.text,
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 18.5, weight: idx == 0 ? .medium : .regular),
                        .foregroundColor: textCol,
                    ]
                )
                // Keep native unboxed cleanliness: only append a whisper-light code hint when rescued or lookup!
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
                btn.setAttributedTitle(attr, for: .normal)
                btn.addAction(UIAction { [weak self] _ in self?.onSelectCandidate?(idx) }, for: .touchUpInside)
                stackView.addArrangedSubview(btn)
            }
        }
        scrollView.setContentOffset(.zero, animated: false)
    }

    @objc private func handleChevron() {
        onTapChevron?()
    }
}

/// Full-keyboard 4-column scrollable Expanded Candidate Grid matching iOS 26 keycap aesthetic.
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

/// Clean iOS 26 Quick Preferences tray (opened via `⌄` when idle or long-pressing mode key).
final class IOSQuickPrefsView: UIView {
    var onUpdatePrefs: ((WubiPreferences) -> Void)?
    var onClose: (() -> Void)?

    private var currentPrefs = WubiPreferences()
    private let schemaSeg = UISegmentedControl(items: ["86 版", "98 版", "新世纪 (06)"])
    private let auto4Switch = UISwitch()
    private let push5Switch = UISwitch()
    private let typoSwitch = UISwitch()
    private let adaptSwitch = UISwitch()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupLayout() {
        let root = UIStackView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.axis = .vertical
        root.spacing = 12
        addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])

        let header = UIStackView()
        header.axis = .horizontal
        let title = UILabel()
        title.text = "五笔版本与纠错设置"
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let doneBtn = UIButton(type: .system)
        doneBtn.setTitle("完成", for: .normal)
        doneBtn.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        doneBtn.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        header.addArrangedSubview(title)
        header.addArrangedSubview(doneBtn)
        root.addArrangedSubview(header)

        schemaSeg.addTarget(self, action: #selector(changed), for: .valueChanged)
        root.addArrangedSubview(schemaSeg)

        let grid = UIStackView()
        grid.axis = .horizontal
        grid.distribution = .fillEqually
        grid.spacing = 14

        let leftCol = UIStackView(arrangedSubviews: [
            makeSwitchRow("四码唯一上屏", sw: auto4Switch),
            makeSwitchRow("第五码顶字", sw: push5Switch),
        ])
        leftCol.axis = .vertical
        leftCol.spacing = 10

        let rightCol = UIStackView(arrangedSubviews: [
            makeSwitchRow("软热区误触纠正", sw: typoSwitch),
            makeSwitchRow("个人热区校准", sw: adaptSwitch),
        ])
        rightCol.axis = .vertical
        rightCol.spacing = 10

        grid.addArrangedSubview(leftCol)
        grid.addArrangedSubview(rightCol)
        root.addArrangedSubview(grid)
    }

    private func makeSwitchRow(_ label: String, sw: UISwitch) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        let l = UILabel()
        l.text = label
        l.font = .systemFont(ofSize: 13.5)
        sw.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
        sw.addTarget(self, action: #selector(changed), for: .valueChanged)
        row.addArrangedSubview(l)
        row.addArrangedSubview(sw)
        return row
    }

    func configure(prefs: WubiPreferences, dark: Bool) {
        currentPrefs = prefs
        backgroundColor = .clear
        schemaSeg.selectedSegmentIndex = (prefs.schemaId == 98) ? 1 : ((prefs.schemaId == 6) ? 2 : 0)
        auto4Switch.isOn = prefs.fourthCodeAutoCommit
        push5Switch.isOn = prefs.fifthCodePushCommit
        typoSwitch.isOn = prefs.typoEnabled
        adaptSwitch.isOn = prefs.touchHitboxAdapt
    }

    @objc private func changed() {
        var p = currentPrefs
        switch schemaSeg.selectedSegmentIndex {
        case 1: p.schemaId = 98
        case 2: p.schemaId = 6
        default: p.schemaId = 86
        }
        p.fourthCodeAutoCommit = auto4Switch.isOn
        p.fifthCodePushCommit = push5Switch.isOn
        p.typoEnabled = typoSwitch.isOn
        p.touchHitboxAdapt = adaptSwitch.isOn
        currentPrefs = p
        onUpdatePrefs?(p)
    }
}
#endif
