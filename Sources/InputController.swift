import AppKit
import InputMethodKit

@objc(PrisWubiInputController)
@MainActor
public final class PrisWubiInputController: IMKInputController {
    private weak var activeClient: (any IMKTextInput & NSObjectProtocol)?
    private var shiftKeyDownAlone: Bool = false
    private var shiftDownTimestamp: TimeInterval = 0

    public override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        self.activeClient = inputClient as? (any IMKTextInput & NSObjectProtocol)
        configurePanelCallbacks()
    }

    private func configurePanelCallbacks() {
        CandidatePanelController.shared.onSelect = { [weak self] relIdx in
            guard let self else { return }
            let out = WubiBridge.shared.selectCandidate(
                pageRelIndex: relIdx,
                timestampMs: Self.nowMs()
            )
            self.applyEngineOutput(out, client: self.activeClient)
        }
        CandidatePanelController.shared.onPage = { [weak self] delta in
            guard let self else { return }
            let out = WubiBridge.shared.turnPage(delta: delta)
            self.applyEngineOutput(out, client: self.activeClient)
        }
    }

    public override func recognizedEvents(_ sender: Any!) -> Int {
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        return Int(mask.rawValue)
    }

    public override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        self.activeClient = sender as? (any IMKTextInput & NSObjectProtocol)
        configurePanelCallbacks()
    }

    public override func deactivateServer(_ sender: Any!) {
        commitPendingAndHide(sender)
        WubiBridge.shared.flushUserDataIfNeeded()
        super.deactivateServer(sender)
    }

    public override func commitComposition(_ sender: Any!) {
        commitPendingAndHide(sender)
        WubiBridge.shared.flushUserDataIfNeeded()
    }

    private func commitPendingAndHide(_ sender: Any!) {
        let clientObj = (sender as? (any IMKTextInput & NSObjectProtocol)) ?? activeClient
        let pre = WubiBridge.shared.state.preedit
        if !pre.isEmpty {
            if let first = WubiBridge.shared.state.candidates.first?.text {
                clientObj?.insertText(first, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            } else {
                clientObj?.insertText(pre, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            }
            WubiBridge.shared.clearComposition()
        }
        CandidatePanelController.shared.hide()
    }

    public override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        let clientObj = (sender as? (any IMKTextInput & NSObjectProtocol)) ?? activeClient
        self.activeClient = clientObj

        // Bare Shift tap detection for seamless Chinese / English toggle
        if event.type == .flagsChanged {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .shift {
                shiftKeyDownAlone = true
                shiftDownTimestamp = event.timestamp
            } else if flags.isEmpty && shiftKeyDownAlone {
                shiftKeyDownAlone = false
                if event.timestamp - shiftDownTimestamp < 0.35 {
                    let out = WubiBridge.shared.toggleAsciiMode()
                    applyEngineOutput(out, client: clientObj)
                    return true
                }
            } else {
                shiftKeyDownAlone = false
            }
            return false
        }

        guard event.type == .keyDown else { return false }
        shiftKeyDownAlone = false

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCmdOrOption = mods.contains(.command) || mods.contains(.option)
        if hasCmdOrOption {
            return false
        }
        let hasCtrl = mods.contains(.control)
        let scalar: UInt32 = event.characters?.unicodeScalars.first?.value ?? 0

        let out = WubiBridge.shared.handleKey(
            keyCode: event.keyCode,
            scalar: scalar,
            hasCmdOrCtrl: hasCtrl,
            timestampMs: Self.nowMs()
        )

        if !out.consumed {
            return false
        }

        applyEngineOutput(out, client: clientObj)
        return true
    }

    private func applyEngineOutput(
        _ out: WubiActionState,
        client: (any IMKTextInput & NSObjectProtocol)?
    ) {
        if out.bell {
            NSSound.beep()
        }

        if !out.commitText.isEmpty {
            client?.insertText(
                out.commitText,
                replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
            )
            WubiBridge.shared.flushUserDataIfNeeded()
        }

        if out.preedit.isEmpty {
            client?.setMarkedText(
                "",
                selectionRange: NSRange(location: 0, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
            )
            CandidatePanelController.shared.hide()
        } else {
            let attr = NSAttributedString(
                string: out.preedit,
                attributes: [
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
            )
            client?.setMarkedText(
                attr,
                selectionRange: NSRange(location: out.preedit.utf16.count, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
            )
            let caret = queryCaretRect(client: client)
            CandidatePanelController.shared.update(state: out, caretRect: caret)
        }
    }

    private func queryCaretRect(client: (any IMKTextInput & NSObjectProtocol)?) -> NSRect {
        var lineRect = NSRect(x: 400, y: 400, width: 1, height: 20)
        if let client {
            _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &lineRect)
        }
        if lineRect.origin == .zero {
            let mouse = NSEvent.mouseLocation
            lineRect = NSRect(x: mouse.x, y: mouse.y, width: 1, height: 20)
        }
        return lineRect
    }

    // MARK: - Native macOS Input Method Menu

    public override func menu() -> NSMenu! {
        let m = NSMenu(title: "棱五笔")
        let curSchema = WubiBridge.shared.prefs.schemaId

        let item86 = NSMenuItem(title: "86 版五笔", action: #selector(selectSchema86(_:)), keyEquivalent: "")
        item86.target = self
        item86.state = (curSchema == 86) ? .on : .off
        m.addItem(item86)

        let item98 = NSMenuItem(title: "98 版五笔", action: #selector(selectSchema98(_:)), keyEquivalent: "")
        item98.target = self
        item98.state = (curSchema == 98) ? .on : .off
        m.addItem(item98)

        let item06 = NSMenuItem(title: "新世纪五笔 (06)", action: #selector(selectSchema06(_:)), keyEquivalent: "")
        item06.target = self
        item06.state = (curSchema == 6) ? .on : .off
        m.addItem(item06)

        m.addItem(.separator())

        let typoItem = NSMenuItem(
            title: "误触与热区置信度纠正",
            action: #selector(toggleTypoCorrection(_:)),
            keyEquivalent: ""
        )
        typoItem.target = self
        typoItem.state = WubiBridge.shared.prefs.typoEnabled ? .on : .off
        m.addItem(typoItem)

        let orientItem = NSMenuItem(
            title: WubiBridge.shared.prefs.vertical ? "切换为横排候选栏" : "切换为竖排候选栏",
            action: #selector(toggleOrientation(_:)),
            keyEquivalent: ""
        )
        orientItem.target = self
        m.addItem(orientItem)

        m.addItem(.separator())

        let prefsItem = NSMenuItem(
            title: "棱五笔偏好设置…",
            action: #selector(openPreferencesWindow(_:)),
            keyEquivalent: ","
        )
        prefsItem.target = self
        m.addItem(prefsItem)

        return m
    }

    @objc private func selectSchema86(_ sender: Any?) {
        WubiBridge.shared.switchSchema(86)
    }

    @objc private func selectSchema98(_ sender: Any?) {
        WubiBridge.shared.switchSchema(98)
    }

    @objc private func selectSchema06(_ sender: Any?) {
        WubiBridge.shared.switchSchema(6)
    }

    @objc private func toggleTypoCorrection(_ sender: Any?) {
        var p = WubiBridge.shared.prefs
        p.typoEnabled.toggle()
        WubiBridge.shared.applyAndSavePreferences(p)
    }

    @objc private func toggleOrientation(_ sender: Any?) {
        var p = WubiBridge.shared.prefs
        p.vertical.toggle()
        WubiBridge.shared.applyAndSavePreferences(p)
    }

    @objc private func openPreferencesWindow(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    private static func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000.0)
    }
}
