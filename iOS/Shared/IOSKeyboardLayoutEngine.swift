import CoreGraphics
import Foundation

public enum IOSKeyPlane: Equatable {
    case letters
    case numbers
    case symbols
}

public enum IOSShiftState: Equatable {
    case lower
    case upperOnce
    case capsLocked

    public var isUppercase: Bool {
        self != .lower
    }
}

public enum IOSReturnKeyRole: Equatable {
    case normal
    case go
    case search
    case send
    case next
    case done
    case join
    case continueRole

    public var title: String {
        switch self {
        case .normal: return "换行"
        case .go: return "前往"
        case .search: return "搜索"
        case .send: return "发送"
        case .next: return "下一项"
        case .done: return "完成"
        case .join: return "加入"
        case .continueRole: return "继续"
        }
    }

    public var isBlueProminent: Bool {
        self != .normal
    }
}

public enum IOSKeyKind: Equatable {
    case letter(UInt8) // 'a'..'z'
    case symbol(String)
    case shift
    case backspace
    case planeSwitch(IOSKeyPlane, label: String)
    case globe
    case modeToggle // 中/英
    case space
    case returnKey
}

public struct IOSKeySpec: Identifiable, Equatable {
    public let id: String
    public let kind: IOSKeyKind
    public let frame: CGRect
    public let primaryLabel: String
    public let systemSymbol: String?
    public let isSystemKey: Bool
    public let isBlueAccent: Bool

    public init(
        id: String,
        kind: IOSKeyKind,
        frame: CGRect,
        primaryLabel: String,
        systemSymbol: String? = nil,
        isSystemKey: Bool = false,
        isBlueAccent: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.primaryLabel = primaryLabel
        self.systemSymbol = systemSymbol
        self.isSystemKey = isSystemKey
        self.isBlueAccent = isBlueAccent
    }
}

/// Pure geometric & state engine for the Apple-native iOS Wubi Virtual Keyboard.
/// Shared across the iOS `UIInputViewController`, unit tests, and 2x/3x Retina offscreen renderers.
public struct IOSKeyboardLayoutEngine {
    public var plane: IOSKeyPlane = .letters
    public var shiftState: IOSShiftState = .lower
    public var asciiMode: Bool = false
    public var schemaId: UInt32 = 86
    public var showGlobeKey: Bool = true
    public var returnRole: IOSReturnKeyRole = .normal
    public var isComposing: Bool = false
    public var isTrackpadActive: Bool = false

    private var lastShiftTapTime: TimeInterval = 0

    public init() {}

    // MARK: - Shift & Plane Transitions

    public mutating func tapShift(at timestamp: TimeInterval) {
        switch shiftState {
        case .lower:
            shiftState = .upperOnce
            lastShiftTapTime = timestamp
        case .upperOnce:
            if timestamp - lastShiftTapTime <= 0.34 {
                shiftState = .capsLocked
            } else {
                shiftState = .lower
            }
            lastShiftTapTime = 0
        case .capsLocked:
            shiftState = .lower
            lastShiftTapTime = 0
        }
    }

    public mutating func consumeOneShotShiftIfNeeded() {
        if shiftState == .upperOnce {
            shiftState = .lower
        }
    }

    public mutating func switchPlane(_ target: IOSKeyPlane) {
        plane = target
        if target != .letters && shiftState == .upperOnce {
            shiftState = .lower
        }
    }

    public var spacebarLabel: String {
        if isTrackpadActive {
            return ""
        }
        if asciiMode {
            return "space"
        }
        switch schemaId {
        case 98: return "空格 · 98五笔"
        case 6: return "空格 · 新世纪"
        default: return "空格 · 86五笔"
        }
    }

    public var effectiveReturnTitle: String {
        if isComposing {
            return "确认英文"
        }
        return returnRole.title
    }

    // MARK: - Exact Apple iOS 4-Row Keycap Geometry

    public struct LayoutSnapshot {
        public let bounds: CGRect
        public let keys: [IOSKeySpec]
        /// 52 floats (`x_a, y_a, ..., x_z, y_z`) in normalized pitch space for `wubi_engine_set_key_layout`.
        public let centers52: [Float]
        public let originX: Float
        public let originY: Float
        public let pitchX: Float
        public let pitchY: Float
    }

    public func computeLayout(in size: CGSize) -> LayoutSnapshot {
        let w = max(240, size.width)
        let h = max(160, size.height)
        let isLandscape = w > 520

        let outerX: CGFloat = isLandscape ? 6.0 : 3.0
        let gapX: CGFloat = isLandscape ? 7.0 : 6.0
        let topPad: CGFloat = isLandscape ? 6.0 : 8.0
        let bottomPad: CGFloat = isLandscape ? 4.0 : 6.0
        let rowGap: CGFloat = isLandscape ? 8.0 : 11.0

        let usableH = h - topPad - bottomPad - rowGap * 3.0
        let keyH = max(32.0, floor(usableH / 4.0))
        let pitchY = keyH + rowGap
        let pitchX = (w - outerX * 2.0) / 10.0
        let stdKeyW = pitchX - gapX

        let rowY: [CGFloat] = [
            topPad,
            topPad + pitchY,
            topPad + pitchY * 2.0,
            topPad + pitchY * 3.0,
        ]

        var specs: [IOSKeySpec] = []

        switch plane {
        case .letters:
            let r0 = Array("qwertyuiop".utf8)
            for (c, b) in r0.enumerated() {
                let cx = outerX + (CGFloat(c) + 0.5) * pitchX
                let frame = CGRect(x: cx - stdKeyW * 0.5, y: rowY[0], width: stdKeyW, height: keyH)
                let label = formatLetter(b)
                specs.append(IOSKeySpec(id: "L_\(b)", kind: .letter(b), frame: frame, primaryLabel: label))
            }

            let r1 = Array("asdfghjkl".utf8)
            for (c, b) in r1.enumerated() {
                let cx = outerX + (CGFloat(c) + 0.5 + 0.5) * pitchX
                let frame = CGRect(x: cx - stdKeyW * 0.5, y: rowY[1], width: stdKeyW, height: keyH)
                let label = formatLetter(b)
                specs.append(IOSKeySpec(id: "L_\(b)", kind: .letter(b), frame: frame, primaryLabel: label))
            }

            // Row 2: Shift + Z..M + Backspace
            let sideSysW = max(stdKeyW * 1.28, pitchX * 1.28 - gapX)
            let shiftSym: String
            switch shiftState {
            case .lower: shiftSym = "shift"
            case .upperOnce: shiftSym = "shift.fill"
            case .capsLocked: shiftSym = "capslock.fill"
            }
            specs.append(
                IOSKeySpec(
                    id: "K_shift",
                    kind: .shift,
                    frame: CGRect(x: outerX + gapX * 0.5, y: rowY[2], width: sideSysW, height: keyH),
                    primaryLabel: "⇧",
                    systemSymbol: shiftSym,
                    isSystemKey: shiftState == .lower
                )
            )

            let r2 = Array("zxcvbnm".utf8)
            for (c, b) in r2.enumerated() {
                let cx = outerX + (CGFloat(c) + 1.5 + 0.5) * pitchX
                let frame = CGRect(x: cx - stdKeyW * 0.5, y: rowY[2], width: stdKeyW, height: keyH)
                let label = formatLetter(b)
                specs.append(IOSKeySpec(id: "L_\(b)", kind: .letter(b), frame: frame, primaryLabel: label))
            }

            specs.append(
                IOSKeySpec(
                    id: "K_backspace",
                    kind: .backspace,
                    frame: CGRect(x: w - outerX - gapX * 0.5 - sideSysW, y: rowY[2], width: sideSysW, height: keyH),
                    primaryLabel: "⌫",
                    systemSymbol: "delete.left",
                    isSystemKey: true
                )
            )

        case .numbers:
            let r0 = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
            appendTenRow(r0, rowIdx: 0, rowY: rowY[0], outerX: outerX, pitchX: pitchX, keyW: stdKeyW, keyH: keyH, into: &specs)

            let r1 = asciiMode
                ? ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""]
                : ["-", "/", "：", "；", "（", "）", "￥", "@", "“", "”"]
            appendTenRow(r1, rowIdx: 1, rowY: rowY[1], outerX: outerX, pitchX: pitchX, keyW: stdKeyW, keyH: keyH, into: &specs)

            let sideSysW = max(stdKeyW * 1.28, pitchX * 1.28 - gapX)
            specs.append(
                IOSKeySpec(
                    id: "P_symbols",
                    kind: .planeSwitch(.symbols, label: "#+="),
                    frame: CGRect(x: outerX + gapX * 0.5, y: rowY[2], width: sideSysW, height: keyH),
                    primaryLabel: "#+=",
                    isSystemKey: true
                )
            )
            let puncMid = asciiMode
                ? [".", ",", "?", "!", "'"]
                : ["。", "，", "、", "？", "！"]
            appendCenteredSymbols(puncMid, rowY: rowY[2], canvasW: w, sideReserved: outerX + sideSysW + gapX * 1.5, gapX: gapX, keyH: keyH, into: &specs)
            specs.append(
                IOSKeySpec(
                    id: "K_backspace",
                    kind: .backspace,
                    frame: CGRect(x: w - outerX - gapX * 0.5 - sideSysW, y: rowY[2], width: sideSysW, height: keyH),
                    primaryLabel: "⌫",
                    systemSymbol: "delete.left",
                    isSystemKey: true
                )
            )

        case .symbols:
            let r0 = ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
            appendTenRow(r0, rowIdx: 0, rowY: rowY[0], outerX: outerX, pitchX: pitchX, keyW: stdKeyW, keyH: keyH, into: &specs)

            let r1 = asciiMode
                ? ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]
                : ["——", "\\", "|", "～", "《", "》", "【", "】", "…", "·"]
            appendTenRow(r1, rowIdx: 1, rowY: rowY[1], outerX: outerX, pitchX: pitchX, keyW: stdKeyW, keyH: keyH, into: &specs)

            let sideSysW = max(stdKeyW * 1.28, pitchX * 1.28 - gapX)
            specs.append(
                IOSKeySpec(
                    id: "P_numbers",
                    kind: .planeSwitch(.numbers, label: "123"),
                    frame: CGRect(x: outerX + gapX * 0.5, y: rowY[2], width: sideSysW, height: keyH),
                    primaryLabel: "123",
                    isSystemKey: true
                )
            )
            let symMid = ["…", "‘", "’", "〈", "〉"]
            appendCenteredSymbols(symMid, rowY: rowY[2], canvasW: w, sideReserved: outerX + sideSysW + gapX * 1.5, gapX: gapX, keyH: keyH, into: &specs)
            specs.append(
                IOSKeySpec(
                    id: "K_backspace",
                    kind: .backspace,
                    frame: CGRect(x: w - outerX - gapX * 0.5 - sideSysW, y: rowY[2], width: sideSysW, height: keyH),
                    primaryLabel: "⌫",
                    systemSymbol: "delete.left",
                    isSystemKey: true
                )
            )
        }

        // Row 3: Bottom System Control Row (`123/ABC` + optional `Globe` + `中/英` + `Space` + `Return`)
        var curX = outerX + gapX * 0.5
        let planeBtnW: CGFloat = max(42, pitchX * 1.18 - gapX)
        let targetPlane: IOSKeyPlane = (plane == .letters) ? .numbers : .letters
        let planeLabel = (plane == .letters) ? "123" : "ABC"
        specs.append(
            IOSKeySpec(
                id: "B_plane",
                kind: .planeSwitch(targetPlane, label: planeLabel),
                frame: CGRect(x: curX, y: rowY[3], width: planeBtnW, height: keyH),
                primaryLabel: planeLabel,
                isSystemKey: true
            )
        )
        curX += planeBtnW + gapX

        if showGlobeKey {
            let globeW: CGFloat = max(38, pitchX * 1.05 - gapX)
            specs.append(
                IOSKeySpec(
                    id: "B_globe",
                    kind: .globe,
                    frame: CGRect(x: curX, y: rowY[3], width: globeW, height: keyH),
                    primaryLabel: "🌐",
                    systemSymbol: "globe",
                    isSystemKey: true
                )
            )
            curX += globeW + gapX
        }

        let modeW: CGFloat = max(40, pitchX * 1.08 - gapX)
        specs.append(
            IOSKeySpec(
                id: "B_mode",
                kind: .modeToggle,
                frame: CGRect(x: curX, y: rowY[3], width: modeW, height: keyH),
                primaryLabel: asciiMode ? "英" : "中",
                isSystemKey: true
            )
        )
        curX += modeW + gapX

        let returnW: CGFloat = max(78, pitchX * 2.28 - gapX)
        let returnX = w - outerX - gapX * 0.5 - returnW
        let spaceW = max(80, returnX - gapX - curX)

        specs.append(
            IOSKeySpec(
                id: "B_space",
                kind: .space,
                frame: CGRect(x: curX, y: rowY[3], width: spaceW, height: keyH),
                primaryLabel: spacebarLabel,
                isSystemKey: false
            )
        )

        specs.append(
            IOSKeySpec(
                id: "B_return",
                kind: .returnKey,
                frame: CGRect(x: returnX, y: rowY[3], width: returnW, height: keyH),
                primaryLabel: effectiveReturnTitle,
                isSystemKey: !returnRole.isBlueProminent,
                isBlueAccent: returnRole.isBlueProminent
            )
        )

        // Compute canonical 26-key normalized centers even when currently viewing 123/#+= plane
        let qOriginX = outerX + 0.5 * pitchX
        let qOriginY = rowY[0] + keyH * 0.5
        var centers52 = [Float](repeating: 0, count: 52)
        for (c, b) in Array("qwertyuiop".utf8).enumerated() {
            let idx = Int(b - UInt8(ascii: "a"))
            centers52[idx * 2] = Float(c)
            centers52[idx * 2 + 1] = 0.0
        }
        for (c, b) in Array("asdfghjkl".utf8).enumerated() {
            let idx = Int(b - UInt8(ascii: "a"))
            centers52[idx * 2] = Float(c) + 0.5
            centers52[idx * 2 + 1] = 1.0
        }
        for (c, b) in Array("zxcvbnm".utf8).enumerated() {
            let idx = Int(b - UInt8(ascii: "a"))
            centers52[idx * 2] = Float(c) + 1.5
            centers52[idx * 2 + 1] = 2.0
        }

        return LayoutSnapshot(
            bounds: CGRect(origin: .zero, size: CGSize(width: w, height: h)),
            keys: specs,
            centers52: centers52,
            originX: Float(qOriginX),
            originY: Float(qOriginY),
            pitchX: Float(pitchX),
            pitchY: Float(pitchY)
        )
    }

    /// Nearest-key Voronoi hit-testing with zero dead zones in keycap gutters!
    public static func hitTest(point: CGPoint, in snapshot: LayoutSnapshot) -> IOSKeySpec? {
        guard snapshot.bounds.insetBy(dx: -8, dy: -8).contains(point) else {
            return nil
        }
        if let direct = snapshot.keys.first(where: { $0.frame.contains(point) }) {
            return direct
        }
        var best: IOSKeySpec?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for k in snapshot.keys {
            // Distance to key's clamped rectangle (so wider keys like Spacebar attract proportionally!)
            let cx = min(max(point.x, k.frame.minX), k.frame.maxX)
            let cy = min(max(point.y, k.frame.minY), k.frame.maxY)
            let d = hypot(point.x - cx, point.y - cy)
            if d < bestDist {
                bestDist = d
                best = k
            }
        }
        return best
    }

    private func formatLetter(_ ascii: UInt8) -> String {
        if isTrackpadActive {
            return ""
        }
        let s = String(UnicodeScalar(ascii))
        if asciiMode && !shiftState.isUppercase {
            return s.lowercased()
        }
        return s.uppercased()
    }

    private func appendTenRow(
        _ labels: [String],
        rowIdx: Int,
        rowY: CGFloat,
        outerX: CGFloat,
        pitchX: CGFloat,
        keyW: CGFloat,
        keyH: CGFloat,
        into specs: inout [IOSKeySpec]
    ) {
        for (c, s) in labels.enumerated() {
            let cx = outerX + (CGFloat(c) + 0.5) * pitchX
            let frame = CGRect(x: cx - keyW * 0.5, y: rowY, width: keyW, height: keyH)
            specs.append(IOSKeySpec(id: "S_\(rowIdx)_\(c)", kind: .symbol(s), frame: frame, primaryLabel: isTrackpadActive ? "" : s))
        }
    }

    private func appendCenteredSymbols(
        _ labels: [String],
        rowY: CGFloat,
        canvasW: CGFloat,
        sideReserved: CGFloat,
        gapX: CGFloat,
        keyH: CGFloat,
        into specs: inout [IOSKeySpec]
    ) {
        guard !labels.isEmpty else { return }
        let availW = canvasW - sideReserved * 2.0
        let n = CGFloat(labels.count)
        let kw = max(28, (availW - gapX * (n - 1)) / n)
        for (i, s) in labels.enumerated() {
            let x = sideReserved + CGFloat(i) * (kw + gapX)
            specs.append(
                IOSKeySpec(
                    id: "SM_\(i)",
                    kind: .symbol(s),
                    frame: CGRect(x: x, y: rowY, width: kw, height: keyH),
                    primaryLabel: isTrackpadActive ? "" : s
                )
            )
        }
    }
}

/// Spacebar horizontal cursor trackpad accumulator (`9.5pt` per character step).
public struct SpaceTrackpadAccumulator {
    public private(set) var isActive: Bool = false
    private var anchorX: CGFloat = 0
    public let stepPoints: CGFloat = 9.5

    public init() {}

    public mutating func begin(at x: CGFloat) {
        isActive = true
        anchorX = x
    }

    /// Updates drag position and returns character offset delta (`..., -1, 0, +1, ...`).
    public mutating func update(x: CGFloat) -> Int {
        guard isActive else { return 0 }
        let diff = x - anchorX
        let steps = Int((diff / stepPoints).rounded(.towardZero))
        if steps != 0 {
            anchorX += CGFloat(steps) * stepPoints
        }
        return steps
    }

    public mutating func end() {
        isActive = false
    }
}
