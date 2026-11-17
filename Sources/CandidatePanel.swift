import AppKit
import SwiftUI

/// Pure native macOS candidate bar view aligned closely to macOS Sequoia / macOS 26 system IME:
/// - Translucent vibrancy backdrop, 11pt continuous corner curve, hairline subtle border
/// - Supports both Horizontal (横排) and Vertical (竖排) candidate presentation
/// - Crisp inline badges for short-code hints (`⚡l`), statistical/touch typo rescue (`⌖trwu 96%`),
///   and Pinyin reverse lookup (`l · lgyi`).
public struct CandidateBarView: View {
    public let state: WubiActionState
    public var onSelectCandidate: ((Int) -> Void)?
    public var onTurnPage: ((Int32) -> Void)?

    public init(
        state: WubiActionState,
        onSelectCandidate: ((Int) -> Void)? = nil,
        onTurnPage: ((Int32) -> Void)? = nil
    ) {
        self.state = state
        self.onSelectCandidate = onSelectCandidate
        self.onTurnPage = onTurnPage
    }

    private var schemaShortLabel: String {
        switch state.schemaId {
        case 98: return "98"
        case 6: return "06"
        default: return "86"
        }
    }

    public var body: some View {
        Group {
            if state.vertical {
                verticalLayout
            } else {
                horizontalLayout
            }
        }
        .fixedSize()
    }

    private var horizontalLayout: some View {
        HStack(spacing: 4) {
            // Compact preedit & schema pill
            HStack(spacing: 5) {
                Text(schemaShortLabel)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))

                Text(state.preedit)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)

            Divider()
                .frame(height: 16)
                .opacity(0.55)
                .padding(.trailing, 2)

            if state.candidates.isEmpty {
                Text("空码")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            } else {
                ForEach(Array(state.candidates.enumerated()), id: \.element.id) { idx, item in
                    candidateCell(item: item, isPrimary: idx == 0, relIndex: idx)
                }
            }

            if state.totalPages > 1 {
                Divider()
                    .frame(height: 15)
                    .opacity(0.45)
                    .padding(.leading, 2)
                pagerControls
                    .padding(.trailing, 6)
            } else {
                Spacer().frame(width: 4)
            }
        }
        .padding(.vertical, 5.5)
        .background(VisualEffectBackdrop(material: .menu, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 10.5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10.5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.13), lineWidth: 0.6)
        )
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(schemaShortLabel)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(state.preedit)
                    .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer(minLength: 16)
                if state.totalPages > 1 {
                    pagerControls
                }
            }
            .padding(.horizontal, 9)
            .padding(.top, 6)
            .padding(.bottom, 3)

            Divider().opacity(0.45)

            if state.candidates.isEmpty {
                Text("无匹配候选词")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 1.5) {
                    ForEach(Array(state.candidates.enumerated()), id: \.element.id) { idx, item in
                        candidateRowVertical(item: item, isPrimary: idx == 0, relIndex: idx)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
            }
        }
        .frame(minWidth: 196)
        .background(VisualEffectBackdrop(material: .menu, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.13), lineWidth: 0.6)
        )
    }

    @ViewBuilder
    private func candidateCell(item: WubiCandidateItem, isPrimary: Bool, relIndex: Int) -> some View {
        Button {
            onSelectCandidate?(relIndex)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(item.index)")
                    .font(.system(size: 12, weight: isPrimary ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(isPrimary ? Color.white.opacity(0.88) : Color.secondary)

                Text(item.text)
                    .font(.system(size: 15.5, weight: isPrimary ? .medium : .regular))
                    .foregroundStyle(isPrimary ? Color.white : Color.primary)

                commentBadge(item: item, isPrimary: isPrimary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                Group {
                    if isPrimary {
                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .fill(Color.accentColor)
                    } else {
                        Color.clear
                    }
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func candidateRowVertical(item: WubiCandidateItem, isPrimary: Bool, relIndex: Int) -> some View {
        Button {
            onSelectCandidate?(relIndex)
        } label: {
            HStack(spacing: 6) {
                Text("\(item.index)")
                    .font(.system(size: 12, weight: isPrimary ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(isPrimary ? Color.white.opacity(0.88) : Color.secondary)
                    .frame(width: 14, alignment: .trailing)

                Text(item.text)
                    .font(.system(size: 15, weight: isPrimary ? .medium : .regular))
                    .foregroundStyle(isPrimary ? Color.white : Color.primary)

                Spacer(minLength: 8)
                commentBadge(item: item, isPrimary: isPrimary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Group {
                    if isPrimary {
                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .fill(Color.accentColor)
                    } else {
                        Color.clear
                    }
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func commentBadge(item: WubiCandidateItem, isPrimary: Bool) -> some View {
        switch item.badgeKind {
        case .typoCorrected where !item.comment.isEmpty:
            Text(item.comment)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(isPrimary ? Color.white : Color.orange)
                .padding(.horizontal, 4.5)
                .padding(.vertical, 1)
                .background(
                    Capsule(style: .continuous)
                        .fill(isPrimary ? Color.white.opacity(0.22) : Color.orange.opacity(0.15))
                )
        case .shortcode where !item.comment.isEmpty:
            Text(item.comment)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(isPrimary ? Color.white.opacity(0.9) : Color.teal)
        case .userPhrase:
            Text("自")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(isPrimary ? Color.white.opacity(0.9) : Color.secondary)
                .padding(.horizontal, 3.5)
                .padding(.vertical, 0.5)
                .background(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(isPrimary ? Color.white.opacity(0.20) : Color.primary.opacity(0.08))
                )
        default:
            if !item.comment.isEmpty {
                Text(item.comment)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(isPrimary ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
    }

    private var pagerControls: some View {
        HStack(spacing: 2) {
            Button {
                onTurnPage?(-1)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(state.page > 0 ? Color.primary : Color.secondary.opacity(0.35))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(state.page == 0)

            Button {
                onTurnPage?(1)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(state.page + 1 < state.totalPages ? Color.primary : Color.secondary.opacity(0.35))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(state.page + 1 >= state.totalPages)
        }
    }
}

public struct VisualEffectBackdrop: NSViewRepresentable {
    public let material: NSVisualEffectView.Material
    public let blendingMode: NSVisualEffectView.BlendingMode

    public init(
        material: NSVisualEffectView.Material = .menu,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

@MainActor
public final class CandidatePanelController {
    public static let shared = CandidatePanelController()

    private let panel: NSPanel
    private let hostingView: NSHostingView<CandidateBarView>
    public var onSelect: ((Int) -> Void)?
    public var onPage: ((Int32) -> Void)?

    private init() {
        let initialView = CandidateBarView(state: .empty)
        self.hostingView = NSHostingView(rootView: initialView)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.contentView = hostingView
        self.panel = p
    }

    public func update(state: WubiActionState, caretRect: NSRect) {
        if state.preedit.isEmpty {
            hide()
            return
        }
        hostingView.rootView = CandidateBarView(
            state: state,
            onSelectCandidate: { [weak self] idx in self?.onSelect?(idx) },
            onTurnPage: { [weak self] d in self?.onPage?(d) }
        )
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let size = NSSize(width: max(120, fitting.width), height: max(32, fitting.height))

        let targetScreen = NSScreen.screens.first(where: { $0.frame.intersects(caretRect) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var originX = caretRect.minX
        var originY = caretRect.minY - size.height - 6

        // Flip above the text line if too close to bottom of screen
        if originY < visible.minY + 8 {
            originY = caretRect.maxY + 6
        }
        if originX + size.width > visible.maxX - 8 {
            originX = max(visible.minX + 8, visible.maxX - size.width - 8)
        }
        if originX < visible.minX + 8 {
            originX = visible.minX + 8
        }

        panel.setFrame(NSRect(origin: NSPoint(x: originX, y: originY), size: size), display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    public func hide() {
        if panel.isVisible {
            panel.orderOut(nil)
        }
    }
}
