import AppKit
import Foundation

public struct WubiCandidateItem: Codable, Identifiable, Equatable {
    public let index: Int
    public let text: String
    public let comment: String
    public let badge: UInt8
    public let confidence: Float
    public let isExact: Bool

    public var id: Int { index }

    public enum BadgeKind {
        case none
        case shortcode
        case typoCorrected
        case wildcard
        case pinyinLookup
        case userPhrase
    }

    public var badgeKind: BadgeKind {
        switch badge {
        case 1: return .shortcode
        case 2: return .typoCorrected
        case 3: return .wildcard
        case 4: return .pinyinLookup
        case 5: return .userPhrase
        default: return .none
        }
    }
}

public struct WubiActionState: Codable, Equatable {
    public let consumed: Bool
    public let bell: Bool
    public let asciiMode: Bool
    public let schemaId: UInt32
    public let page: Int
    public let totalPages: Int
    public let vertical: Bool
    public let schemaName: String
    public let commitText: String
    public let preedit: String
    public let notice: String
    public let userPhraseCount: Int
    public let calibratedKeyCount: Int
    public let candidates: [WubiCandidateItem]

    public static let empty = WubiActionState(
        consumed: false,
        bell: false,
        asciiMode: false,
        schemaId: 86,
        page: 0,
        totalPages: 0,
        vertical: false,
        schemaName: "86版五笔",
        commitText: "",
        preedit: "",
        notice: "",
        userPhraseCount: 0,
        calibratedKeyCount: 0,
        candidates: []
    )
}

public struct UserPhraseRecord: Codable, Identifiable, Equatable {
    public let text: String
    public let code: String
    public let count: UInt32
    public let auto: Bool
    public var id: String { text }
}

public struct WubiPreferences: Equatable {
    public var schemaId: UInt32 = 86
    public var pageSize: Int = 5
    public var vertical: Bool = false
    public var shiftToggleMode: String = "commit_code"
    public var smartPunctuation: Bool = true
    public var semicolonQuoteSelect: Bool = false

    public var fourthCodeAutoCommit: Bool = true
    public var fifthCodePushCommit: Bool = true
    public var fourthEmptyBehavior: String = "block"
    public var shortestCodeFirst: Bool = true
    public var strictShortcode: Bool = false
    public var showShortcodeHint: Bool = true
    public var dynamicWordFreq: Bool = true
    public var dynamicCharFreq: Bool = false
    public var autoPhrase: Bool = true
    public var autoPhraseThreshold: Int = 2
    public var zOmnipotent: Bool = true
    public var enableRareCharset: Bool = false

    public var typoEnabled: Bool = true
    public var touchHitboxAdapt: Bool = true
    public var promoteThreshold: Double = 0.82
    public var suggestThreshold: Double = 0.30
    public var suppressAutoCommitOnCorrection: Bool = true

    public init() {}

    public func toTOML() -> String {
        let schemaTag: String
        switch schemaId {
        case 98: schemaTag = "98"
        case 6: schemaTag = "06"
        default: schemaTag = "86"
        }
        return """
        # 棱五笔 (PrisWubi) 配置文件 — macOS 与 iOS 通用内核
        # 修改保存后将实时生效

        [general]
        schema = "\(schemaTag)"
        page_size = \(pageSize)
        orientation = "\(vertical ? "vertical" : "horizontal")"
        shift_toggle_mode = "\(shiftToggleMode)"
        smart_punctuation = \(smartPunctuation)
        semicolon_quote_select = \(semicolonQuoteSelect)

        [typing]
        fourth_code_auto_commit = \(fourthCodeAutoCommit)
        fifth_code_push_commit = \(fifthCodePushCommit)
        fourth_empty_behavior = "\(fourthEmptyBehavior)"
        shortest_code_first = \(shortestCodeFirst)
        strict_shortcode = \(strictShortcode)
        show_shortcode_hint = \(showShortcodeHint)
        dynamic_word_freq = \(dynamicWordFreq)
        dynamic_char_freq = \(dynamicCharFreq)
        auto_phrase = \(autoPhrase)
        auto_phrase_threshold = \(autoPhraseThreshold)
        z_omnipotent = \(zOmnipotent)
        enable_rare_charset = \(enableRareCharset)

        [typo_correction]
        enabled = \(typoEnabled)
        touch_hitbox_adapt = \(touchHitboxAdapt)
        promote_threshold = \(String(format: "%.2f", promoteThreshold))
        suggest_threshold = \(String(format: "%.2f", suggestThreshold))
        suppress_auto_commit_on_correction = \(suppressAutoCommitOnCorrection)
        """
    }

    public static func fromTOML(_ toml: String) -> WubiPreferences {
        var p = WubiPreferences()
        var section = ""
        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let clean = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let line = clean.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let val = parts[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let boolVal = ["true", "1", "yes"].contains(val.lowercased())

            switch (section, key) {
            case (_, "schema"):
                if val == "98" { p.schemaId = 98 }
                else if val == "06" || val == "2006" { p.schemaId = 6 }
                else { p.schemaId = 86 }
            case (_, "page_size"):
                p.pageSize = min(9, max(3, Int(val) ?? 5))
            case (_, "orientation"):
                p.vertical = (val.lowercased() == "vertical")
            case (_, "shift_toggle_mode"):
                p.shiftToggleMode = val
            case (_, "smart_punctuation"):
                p.smartPunctuation = boolVal
            case (_, "semicolon_quote_select"):
                p.semicolonQuoteSelect = boolVal
            case (_, "fourth_code_auto_commit"):
                p.fourthCodeAutoCommit = boolVal
            case (_, "fifth_code_push_commit"):
                p.fifthCodePushCommit = boolVal
            case (_, "fourth_empty_behavior"):
                p.fourthEmptyBehavior = val
            case (_, "shortest_code_first"):
                p.shortestCodeFirst = boolVal
            case (_, "strict_shortcode"):
                p.strictShortcode = boolVal
            case (_, "show_shortcode_hint"):
                p.showShortcodeHint = boolVal
            case (_, "dynamic_word_freq"):
                p.dynamicWordFreq = boolVal
            case (_, "dynamic_char_freq"):
                p.dynamicCharFreq = boolVal
            case (_, "auto_phrase"):
                p.autoPhrase = boolVal
            case (_, "auto_phrase_threshold"):
                p.autoPhraseThreshold = min(5, max(1, Int(val) ?? 2))
            case (_, "z_omnipotent"):
                p.zOmnipotent = boolVal
            case (_, "enable_rare_charset"):
                p.enableRareCharset = boolVal
            case ("typo_correction", "enabled"):
                p.typoEnabled = boolVal
            case (_, "touch_hitbox_adapt"):
                p.touchHitboxAdapt = boolVal
            case (_, "promote_threshold"):
                p.promoteThreshold = min(0.99, max(0.50, Double(val) ?? 0.82))
            case (_, "suggest_threshold"):
                p.suggestThreshold = min(0.85, max(0.10, Double(val) ?? 0.30))
            case (_, "suppress_auto_commit_on_correction"):
                p.suppressAutoCommitOnCorrection = boolVal
            default:
                break
            }
        }
        return p
    }
}

@MainActor
public final class WubiBridge: ObservableObject {
    public static let shared = WubiBridge()

    private var handle: OpaquePointer?
    private let decoder = JSONDecoder()

    @Published public private(set) var state: WubiActionState = .empty
    @Published public var prefs: WubiPreferences = WubiPreferences()
    @Published public private(set) var userPhrases: [UserPhraseRecord] = []

    public let configURL: URL
    public let userDataURL: URL

    public init(customDictsDir: URL? = nil, inMemoryOnly: Bool = false) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dotfile = home.appendingPathComponent(".priswubi.toml")
        let appSupport = home
            .appendingPathComponent("Library/Application Support/PrisWubi", isDirectory: true)
        if !inMemoryOnly {
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: dotfile.path) {
            self.configURL = dotfile
        } else {
            self.configURL = appSupport.appendingPathComponent("config.toml")
        }
        self.userDataURL = appSupport.appendingPathComponent("user_data.tsv")

        self.handle = wubi_engine_new()
        loadDictionaries(overrideDir: customDictsDir)
        if !inMemoryOnly {
            loadConfigAndUser()
        } else {
            refreshState()
        }
    }

    deinit {
        if let h = handle {
            wubi_engine_free(h)
        }
    }

    public func loadDictionaries(overrideDir: URL? = nil) {
        guard let h = handle else { return }
        let candidateDirs: [URL] = [
            overrideDir,
            Bundle.main.resourceURL?.appendingPathComponent("Dicts", isDirectory: true),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/Dicts", isDirectory: true),
        ].compactMap { $0 }

        for dir in candidateDirs {
            let p86 = dir.appendingPathComponent("wubi86.wbdict").path
            if FileManager.default.fileExists(atPath: p86) {
                _ = p86.withCString { wubi_engine_load_dict_mmap(h, 86, $0) }
                let p98 = dir.appendingPathComponent("wubi98.wbdict").path
                _ = p98.withCString { wubi_engine_load_dict_mmap(h, 98, $0) }
                let p06 = dir.appendingPathComponent("wubi06.wbdict").path
                _ = p06.withCString { wubi_engine_load_dict_mmap(h, 6, $0) }
                let pAux = dir.appendingPathComponent("wubi_aux.wbaux").path
                _ = pAux.withCString { wubi_engine_load_aux_mmap(h, $0) }
                break
            }
        }
    }

    public func loadConfigAndUser() {
        guard let h = handle else { return }
        if FileManager.default.fileExists(atPath: configURL.path) {
            _ = configURL.path.withCString { wubi_engine_load_config(h, $0) }
        } else {
            _ = configURL.path.withCString { wubi_engine_save_config(h, $0) }
        }
        if FileManager.default.fileExists(atPath: userDataURL.path) {
            _ = userDataURL.path.withCString { wubi_engine_load_user_data(h, $0) }
        }
        let toml = takeString(wubi_engine_get_config_toml(h))
        self.prefs = WubiPreferences.fromTOML(toml)
        refreshState()
        refreshUserPhrases()
    }

    public func applyAndSavePreferences(_ newPrefs: WubiPreferences, persist: Bool = true) {
        guard let h = handle else { return }
        self.prefs = newPrefs
        let toml = newPrefs.toTOML()
        toml.withCString { wubi_engine_set_config_toml(h, $0) }
        if persist {
            _ = configURL.path.withCString { wubi_engine_save_config(h, $0) }
        }
        refreshState()
        refreshUserPhrases()
    }

    public func switchSchema(_ schemaId: UInt32, persist: Bool = true) {
        var updated = prefs
        updated.schemaId = schemaId
        applyAndSavePreferences(updated, persist: persist)
    }

    public func flushUserDataIfNeeded() {
        guard let h = handle else { return }
        if wubi_engine_is_user_dirty(h) {
            _ = userDataURL.path.withCString { wubi_engine_save_user_data(h, $0) }
            refreshUserPhrases()
        }
    }

    public func handleKey(
        keyCode: UInt16,
        scalar: UInt32,
        hasCmdOrCtrl: Bool,
        timestampMs: UInt64
    ) -> WubiActionState {
        guard let h = handle else { return .empty }
        let json = takeString(wubi_engine_handle_key_json(h, keyCode, scalar, hasCmdOrCtrl, timestampMs))
        let decoded = decodeState(json)
        self.state = decoded
        return decoded
    }

    public func pushTouch(
        reportedAscii: UInt8,
        x: Float,
        y: Float,
        isNormalized: Bool,
        timestampMs: UInt64
    ) -> WubiActionState {
        guard let h = handle else { return .empty }
        let json = takeString(wubi_engine_push_touch_json(h, reportedAscii, x, y, isNormalized, timestampMs))
        let decoded = decodeState(json)
        self.state = decoded
        return decoded
    }

    public func selectCandidate(pageRelIndex: Int, timestampMs: UInt64) -> WubiActionState {
        guard let h = handle else { return .empty }
        let json = takeString(wubi_engine_select_candidate_json(h, UInt32(max(0, pageRelIndex)), timestampMs))
        let decoded = decodeState(json)
        self.state = decoded
        return decoded
    }

    public func turnPage(delta: Int32) -> WubiActionState {
        guard let h = handle else { return .empty }
        let json = takeString(wubi_engine_page_turn_json(h, delta))
        let decoded = decodeState(json)
        self.state = decoded
        return decoded
    }

    public func toggleAsciiMode() -> WubiActionState {
        guard let h = handle else { return .empty }
        let json = takeString(wubi_engine_toggle_ascii_json(h))
        let decoded = decodeState(json)
        self.state = decoded
        return decoded
    }

    public func clearComposition() {
        guard let h = handle else { return }
        wubi_engine_clear(h)
        refreshState()
    }

    @discardableResult
    public func addUserPhrase(_ text: String, persist: Bool = true) -> String {
        guard let h = handle else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return "" }
        let code = trimmed.withCString { takeString(wubi_engine_add_user_phrase(h, $0)) }
        if !code.isEmpty && persist {
            flushUserDataIfNeeded()
        }
        refreshState()
        refreshUserPhrases()
        return code
    }

    public func removeUserPhrase(_ text: String, persist: Bool = true) {
        guard let h = handle else { return }
        _ = text.withCString { wubi_engine_remove_user_phrase(h, $0) }
        if persist {
            flushUserDataIfNeeded()
        }
        refreshState()
        refreshUserPhrases()
    }

    public func resetTouchCalibration(persist: Bool = true) {
        guard let h = handle else { return }
        wubi_engine_reset_touch_profile(h)
        if persist {
            flushUserDataIfNeeded()
        }
        refreshState()
    }

    public func refreshUserPhrases() {
        guard let h = handle else { return }
        let json = takeString(wubi_engine_list_user_phrases_json(h))
        if let data = json.data(using: .utf8),
           let list = try? decoder.decode([UserPhraseRecord].self, from: data) {
            self.userPhrases = list
        }
    }

    public func refreshState() {
        guard let h = handle else { return }
        let json = takeString(wubi_engine_state_json(h))
        self.state = decodeState(json)
    }

    private func decodeState(_ json: String) -> WubiActionState {
        guard let data = json.data(using: .utf8),
              let s = try? decoder.decode(WubiActionState.self, from: data) else {
            return .empty
        }
        return s
    }

    private func takeString(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
        guard let p = ptr else { return "" }
        defer { wubi_string_free(p) }
        return String(cString: p)
    }
}
