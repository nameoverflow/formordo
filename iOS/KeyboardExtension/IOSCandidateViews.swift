#if os(iOS)
import UIKit

/// Top 44pt Candidate & Quick-Toolbar Ribbon for iOS Virtual Keyboard.
final class IOSCandidateRibbonView: UIView {
    var onSelectCandidate: ((Int) -> Void)?
    var onToggleExpand: (() -> Void)?
    var onCycleSchema: (() -> Void)?
    var onToggleMode: (() -> Void)?
    var onQuickPunctuation: ((String) -> Void)?
    var onToggleQuickPrefs: (() -> Void)?

    private let idleContainer = UIView()
    private let composingContainer = UIView()

    private let schemaPill = UIButton(type: .system)
    private let modePill = UIButton(type: .system)
    private let puncStack = UIStackView()
    private let prefsBtn = UIButton(type: .system)

    private let preeditBadge = UILabel()
    private let candScroll = UIScrollView()
    private let candStack = UIStackView()
    private let expandBtn = UIButton(type: .system)
    private let divider = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupHierarchy()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupHierarchy() {
        idleContainer.translatesAutoresizingMaskIntoConstraints = false
        composingContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(idleContainer)
        addSubview(composingContainer)

        NSLayoutConstraint.activate([
            idleContainer.topAnchor.constraint(equalTo: topAnchor),
            idleContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            idleContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            idleContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            composingContainer.topAnchor.constraint(equalTo: topAnchor),
            composingContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            composingContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            composingContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // 1. Idle Quick Bar
        schemaPill.translatesAutoresizingMaskIntoConstraints = false
        schemaPill.titleLabel?.font = .systemFont(ofSize: 12.5, weight: .semibold)
        schemaPill.layer.cornerRadius = 13
        schemaPill.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        schemaPill.addTarget(self, action: #selector(tapSchema), for: .touchUpInside)

        modePill.translatesAutoresizingMaskIntoConstraints = false
        modePill.titleLabel?.font = .systemFont(ofSize: 12.5, weight: .medium)
        modePill.layer.cornerRadius = 13
        modePill.contentEdgeInsets = UIEdgeInsets(top: 4, left: 9, bottom: 4, right: 9)
        modePill.addTarget(self, action: #selector(tapMode), for: .touchUpInside)

        puncStack.translatesAutoresizingMaskIntoConstraints = false
        puncStack.axis = .horizontal
        puncStack.distribution = .fillEqually
        puncStack.spacing = 2
        for sym in ["，", "。", "？", "！", "、", "“”"] {
            let b = UIButton(type: .system)
            b.setTitle(sym, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 16, weight: .regular)
            b.addAction(UIAction { [weak self] _ in self?.onQuickPunctuation?(sym) }, for: .touchUpInside)
            puncStack.addArrangedSubview(b)
        }

        prefsBtn.translatesAutoresizingMaskIntoConstraints = false
        prefsBtn.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        prefsBtn.addTarget(self, action: #selector(tapPrefs), for: .touchUpInside)

        idleContainer.addSubview(schemaPill)
        idleContainer.addSubview(modePill)
        idleContainer.addSubview(puncStack)
        idleContainer.addSubview(prefsBtn)

        NSLayoutConstraint.activate([
            schemaPill.leadingAnchor.constraint(equalTo: idleContainer.leadingAnchor, constant: 8),
            schemaPill.centerYAnchor.constraint(equalTo: idleContainer.centerYAnchor),

            modePill.leadingAnchor.constraint(equalTo: schemaPill.trailingAnchor, constant: 6),
            modePill.centerYAnchor.constraint(equalTo: idleContainer.centerYAnchor),

            puncStack.leadingAnchor.constraint(equalTo: modePill.trailingAnchor, constant: 6),
            puncStack.trailingAnchor.constraint(equalTo: prefsBtn.leadingAnchor, constant: -4),
            puncStack.centerYAnchor.constraint(equalTo: idleContainer.centerYAnchor),

            prefsBtn.trailingAnchor.constraint(equalTo: idleContainer.trailingAnchor, constant: -8),
            prefsBtn.centerYAnchor.constraint(equalTo: idleContainer.centerYAnchor),
            prefsBtn.widthAnchor.constraint(equalToConstant: 34),
        ])

        // 2. Composing Candidate Strip
        preeditBadge.translatesAutoresizingMaskIntoConstraints = false
        preeditBadge.font = .monospacedSystemFont(ofSize: 13.5, weight: .semibold)
        preeditBadge.layer.cornerRadius = 6
        preeditBadge.layer.masksToBounds = true
        preeditBadge.textAlignment = .center

        candScroll.translatesAutoresizingMaskIntoConstraints = false
        candScroll.showsHorizontalScrollIndicator = false
        candStack.translatesAutoresizingMaskIntoConstraints = false
        candStack.axis = .horizontal
        candStack.spacing = 6
        candScroll.addSubview(candStack)

        divider.translatesAutoresizingMaskIntoConstraints = false
        expandBtn.translatesAutoresizingMaskIntoConstraints = false
        expandBtn.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        expandBtn.addTarget(self, action: #selector(tapExpand), for: .touchUpInside)

        composingContainer.addSubview(preeditBadge)
        composingContainer.addSubview(candScroll)
        composingContainer.addSubview(divider)
        composingContainer.addSubview(expandBtn)

        NSLayoutConstraint.activate([
            preeditBadge.leadingAnchor.constraint(equalTo: composingContainer.leadingAnchor, constant: 8),
            preeditBadge.centerYAnchor.constraint(equalTo: composingContainer.centerYAnchor),
            preeditBadge.heightAnchor.constraint(equalToConstant: 24),
            preeditBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),

            candScroll.leadingAnchor.constraint(equalTo: preeditBadge.trailingAnchor, constant: 6),
            candScroll.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            candScroll.topAnchor.constraint(equalTo: composingContainer.topAnchor),
            candScroll.bottomAnchor.constraint(equalTo: composingContainer.bottomAnchor),

            candStack.leadingAnchor.constraint(equalTo: candScroll.contentLayoutGuide.leadingAnchor, constant: 4),
            candStack.trailingAnchor.constraint(equalTo: candScroll.contentLayoutGuide.trailingAnchor, constant: -8),
            candStack.centerYAnchor.constraint(equalTo: candScroll.frameLayoutGuide.centerYAnchor),

            divider.trailingAnchor.constraint(equalTo: expandBtn.leadingAnchor),
            divider.centerYAnchor.constraint(equalTo: composingContainer.centerYAnchor),
            divider.widthAnchor.constraint(equalToConstant: 0.6),
            divider.heightAnchor.constraint(equalToConstant: 22),

            expandBtn.trailingAnchor.constraint(equalTo: composingContainer.trailingAnchor),
            expandBtn.topAnchor.constraint(equalTo: composingContainer.topAnchor),
            expandBtn.bottomAnchor.constraint(equalTo: composingContainer.bottomAnchor),
            expandBtn.widthAnchor.constraint(equalToConstant: 42),
        ])
    }

    func setExpanded(_ expanded: Bool) {
        let icon = expanded ? "chevron.up" : "chevron.down"
        expandBtn.setImage(UIImage(systemName: icon), for: .normal)
    }

    func update(state: WubiActionState, dark: Bool) {
        let primaryCol: UIColor = dark ? .white : .black
        let secondaryCol: UIColor = dark ? UIColor(white: 0.72, alpha: 1.0) : UIColor(white: 0.38, alpha: 1.0)
        let pillBg = (dark ? UIColor.white : UIColor.black).withAlphaComponent(0.09)

        let isComposing = !state.preedit.isEmpty
        idleContainer.isHidden = isComposing
        composingContainer.isHidden = !isComposing

        let sTag = (state.schemaId == 98) ? "98五笔" : ((state.schemaId == 6) ? "新世纪" : "86五笔")
        schemaPill.setTitle(sTag, for: .normal)
        schemaPill.backgroundColor = pillBg
        schemaPill.setTitleColor(primaryCol, for: .normal)

        modePill.setTitle(state.asciiMode ? "英" : "中", for: .normal)
        modePill.backgroundColor = pillBg
        modePill.setTitleColor(primaryCol, for: .normal)

        prefsBtn.tintColor = secondaryCol
        puncStack.arrangedSubviews.compactMap { $0 as? UIButton }.forEach {
            $0.setTitleColor(primaryCol, for: .normal)
        }

        guard isComposing else { return }
        preeditBadge.text = " \(state.preedit) "
        preeditBadge.textColor = primaryCol
        preeditBadge.backgroundColor = pillBg
        divider.backgroundColor = secondaryCol.withAlphaComponent(0.35)
        expandBtn.tintColor = primaryCol

        candStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (idx, item) in state.candidates.enumerated() {
            let chip = makeCandidateChip(item: item, isPrimary: idx == 0, relIndex: idx, dark: dark)
            candStack.addArrangedSubview(chip)
        }
        candScroll.setContentOffset(.zero, animated: false)
    }

    private func makeCandidateChip(
        item: WubiCandidateItem,
        isPrimary: Bool,
        relIndex: Int,
        dark: Bool
    ) -> UIView {
        let btn = UIButton(type: .custom)
        btn.layer.cornerRadius = 7
        btn.contentEdgeInsets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        if isPrimary {
            btn.backgroundColor = (dark ? UIColor.white : UIColor.black).withAlphaComponent(0.11)
        }

        let attr = NSMutableAttributedString(
            string: item.text,
            attributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: isPrimary ? .semibold : .regular),
                .foregroundColor: dark ? UIColor.white : UIColor.black,
            ]
        )
        if !item.comment.isEmpty {
            let badgeCol: UIColor
            switch item.badgeKind {
            case .typoCorrected: badgeCol = .systemOrange
            case .shortcode: badgeCol = .systemTeal
            default: badgeCol = dark ? UIColor(white: 0.70, alpha: 1) : .secondaryLabel
            }
            attr.append(
                NSAttributedString(
                    string: " \(item.comment)",
                    attributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                        .foregroundColor: badgeCol,
                    ]
                )
            )
        }
        btn.setAttributedTitle(attr, for: .normal)
        btn.addAction(UIAction { [weak self] _ in self?.onSelectCandidate?(relIndex) }, for: .touchUpInside)
        return btn
    }

    @objc private func tapSchema() { onCycleSchema?() }
    @objc private func tapMode() { onToggleMode?() }
    @objc private func tapExpand() { onToggleExpand?() }
    @objc private func tapPrefs() { onToggleQuickPrefs?() }
}

/// Full-keyboard 4-column scrollable Expanded Candidate Grid + right action rail (`⌃ / ⌫ / 清空`).
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
        gridStack.spacing = 6

        railStack.translatesAutoresizingMaskIntoConstraints = false
        railStack.axis = .vertical
        railStack.distribution = .fillEqually
        railStack.spacing = 6

        scrollView.addSubview(gridStack)
        addSubview(scrollView)
        addSubview(railStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            scrollView.trailingAnchor.constraint(equalTo: railStack.leadingAnchor, constant: -6),

            gridStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            gridStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            gridStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            gridStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            gridStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            railStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            railStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            railStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            railStack.widthAnchor.constraint(equalToConstant: 52),
        ])

        let collapseBtn = makeRailButton(title: "收起", symbol: "chevron.up") { [weak self] in self?.onCollapse?() }
        let delBtn = makeRailButton(title: nil, symbol: "delete.left") { [weak self] in self?.onBackspace?() }
        let clrBtn = makeRailButton(title: "重输", symbol: nil) { [weak self] in self?.onClear?() }
        railStack.addArrangedSubview(collapseBtn)
        railStack.addArrangedSubview(delBtn)
        railStack.addArrangedSubview(clrBtn)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reload(candidates: [WubiCandidateItem], dark: Bool) {
        backgroundColor = dark
            ? UIColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 0.98)
            : UIColor(red: 0.83, green: 0.85, blue: 0.88, alpha: 0.98)

        let cellBg = dark ? UIColor(white: 0.28, alpha: 1) : UIColor.white
        let textCol = dark ? UIColor.white : UIColor.black

        gridStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let cols = 4
        var idx = 0
        while idx < candidates.count {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 6
            for c in 0..<cols {
                if idx + c < candidates.count {
                    let item = candidates[idx + c]
                    let absIdx = idx + c
                    let btn = UIButton(type: .system)
                    btn.backgroundColor = cellBg
                    btn.layer.cornerRadius = 6
                    btn.setTitle(item.text, for: .normal)
                    btn.setTitleColor(textCol, for: .normal)
                    btn.titleLabel?.font = .systemFont(ofSize: 16.5, weight: absIdx == 0 ? .semibold : .regular)
                    btn.heightAnchor.constraint(equalToConstant: 40).isActive = true
                    btn.addAction(UIAction { [weak self] _ in self?.onSelectAbsCandidate?(absIdx) }, for: .touchUpInside)
                    row.addArrangedSubview(btn)
                } else {
                    let spacer = UIView()
                    row.addArrangedSubview(spacer)
                }
            }
            gridStack.addArrangedSubview(row)
            idx += cols
        }
    }

    private func makeRailButton(title: String?, symbol: String?, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.backgroundColor = UIColor.secondarySystemFill
        b.layer.cornerRadius = 6
        if let s = symbol {
            b.setImage(UIImage(systemName: s), for: .normal)
        } else {
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        }
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }
}

/// In-keyboard Quick Preferences sheet — works 100% offline even when "Allow Full Access" is OFF!
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
        root.spacing = 10
        addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])

        let header = UIStackView()
        header.axis = .horizontal
        let title = UILabel()
        title.text = "键盘内快捷设置（免完全访问即可生效）"
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let doneBtn = UIButton(type: .system)
        doneBtn.setTitle("返回键盘", for: .normal)
        doneBtn.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        doneBtn.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        header.addArrangedSubview(title)
        header.addArrangedSubview(doneBtn)
        root.addArrangedSubview(header)

        schemaSeg.addTarget(self, action: #selector(changed), for: .valueChanged)
        root.addArrangedSubview(schemaSeg)

        let grid = UIStackView()
        grid.axis = .horizontal
        grid.distribution = .fillEqually
        grid.spacing = 12

        let leftCol = UIStackView(arrangedSubviews: [
            makeSwitchRow("四码唯一上屏", sw: auto4Switch),
            makeSwitchRow("第五码顶字", sw: push5Switch),
        ])
        leftCol.axis = .vertical
        leftCol.spacing = 8

        let rightCol = UIStackView(arrangedSubviews: [
            makeSwitchRow("贝叶斯误触纠正", sw: typoSwitch),
            makeSwitchRow("个人热区自适应", sw: adaptSwitch),
        ])
        rightCol.axis = .vertical
        rightCol.spacing = 8

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
        l.font = .systemFont(ofSize: 13)
        sw.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
        sw.addTarget(self, action: #selector(changed), for: .valueChanged)
        row.addArrangedSubview(l)
        row.addArrangedSubview(sw)
        return row
    }

    func configure(prefs: WubiPreferences, dark: Bool) {
        currentPrefs = prefs
        backgroundColor = dark
            ? UIColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 0.98)
            : UIColor(red: 0.88, green: 0.90, blue: 0.93, alpha: 0.98)
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
