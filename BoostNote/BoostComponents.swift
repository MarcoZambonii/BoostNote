import SwiftUI

// I componenti del sistema chiuso — firme dal §8 del README del kit,
// anatomia quotata da System.jsx. Nessun valore raw: tutto dai token.

// MARK: - Ruoli semantici dei segnali (badge, toast)

enum SemanticRole {
    case neutral, success, attention, danger, review, insight, brand

    var ink: Color {
        switch self {
        case .neutral: DesignColor.textSecondary
        case .success: DesignColor.success
        case .attention: DesignColor.attention
        case .danger: DesignColor.danger
        case .review: DesignColor.review
        case .insight: DesignColor.insight
        case .brand: DesignColor.brandPrimary
        }
    }

    var background: Color {
        switch self {
        case .neutral: DesignColor.surfaceSunken
        case .success: DesignColor.successBg
        case .attention: DesignColor.attentionBg
        case .danger: DesignColor.dangerBg
        case .review: DesignColor.reviewBg
        case .insight: DesignColor.insightBg
        case .brand: DesignColor.brandPrimarySubtle
        }
    }
}

// MARK: - BoostButton

// Bottone standard: altezza 44 (38 solo nelle testate di card e
// pannelli), raggio md, testo action, icona 14. Quattro toni:
// primary (l'UNICA azione blu della schermata), secondary (neutro con
// hairline), ghost, destructive. Assorbe il vecchio BoostButtonStyle,
// che a ~30 pt stava sotto il minimo di tocco iPad.
struct BoostButton: View {
    enum Tone { case primary, secondary, ghost, destructive }
    enum Size { case regular, compact }

    let title: String
    var icon: String?
    var tone: Tone
    var size: Size
    var isLoading: Bool
    var fullWidth: Bool
    let action: () -> Void

    init(_ title: String, icon: String? = nil, tone: Tone = .secondary,
         size: Size = .regular, isLoading: Bool = false, fullWidth: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.tone = tone
        self.size = size
        self.isLoading = isLoading
        self.fullWidth = fullWidth
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(ink)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: DesignIcon.sm, weight: .semibold))
                }
                Text(isLoading ? "Attendi…" : title)
                    .lineLimit(1)
            }
            .font(DesignFont.action)
            .foregroundStyle(ink)
            .padding(.horizontal, DesignSpace.s4)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: size == .compact ? DesignSize.compact : DesignSize.control)
            .background(face, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                    .strokeBorder(ring, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
        }
        .buttonStyle(BoostPressStyle())
        .disabled(isLoading)
    }

    private var ink: Color {
        switch tone {
        case .primary: DesignColor.textOnBrand
        case .secondary: DesignColor.textPrimary
        case .ghost: DesignColor.textSecondary
        case .destructive: DesignColor.danger
        }
    }

    private var face: Color {
        switch tone {
        case .primary: DesignColor.brandPrimary
        case .secondary, .destructive: DesignColor.surfacePage
        case .ghost: .clear
        }
    }

    private var ring: Color {
        switch tone {
        case .primary, .ghost: .clear
        case .secondary: DesignColor.borderDefault
        case .destructive: DesignColor.danger
        }
    }
}

// Pressione (opacity .7) e disabilitazione (opacity .4), come da
// anatomia dei bottoni in System.jsx.
private struct BoostPressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

// MARK: - BoostIconButton

// Tasto icona: 44×44 SEMPRE, anche quando il glifo è 17. Raggio md.
struct BoostIconButton: View {
    enum Tone { case neutral, brand, destructive }

    let systemName: String
    var tone: Tone
    let action: () -> Void

    init(_ systemName: String, tone: Tone = .neutral, action: @escaping () -> Void) {
        self.systemName = systemName
        self.tone = tone
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: DesignIcon.md))
                .foregroundStyle(ink)
                .frame(width: DesignSize.touchMin, height: DesignSize.touchMin)
                .background(face, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
        }
        .buttonStyle(BoostPressStyle())
    }

    private var ink: Color {
        switch tone {
        case .neutral: DesignColor.textSecondary
        case .brand: DesignColor.brandPrimary
        case .destructive: DesignColor.danger
        }
    }

    private var face: Color {
        tone == .brand ? DesignColor.brandPrimarySubtle : .clear
    }
}

// MARK: - BoostBadge

struct BoostBadgeModel {
    let text: String
    var role: SemanticRole = .neutral
    var uppercase: Bool = false
}

// Badge: micro su fondo tenue del ruolo, raggio sm. MAIUSCOLO solo con
// uppercase (tracking 0.6, come --track-micro).
struct BoostBadge: View {
    let model: BoostBadgeModel

    init(_ text: String, role: SemanticRole = .neutral, uppercase: Bool = false) {
        model = BoostBadgeModel(text: text, role: role, uppercase: uppercase)
    }

    init(model: BoostBadgeModel) {
        self.model = model
    }

    var body: some View {
        Text(model.uppercase ? model.text.uppercased() : model.text)
            .font(DesignFont.micro)
            .tracking(model.uppercase ? 0.6 : 0)
            .foregroundStyle(model.role.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(model.role.background, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
            .lineLimit(1)
    }
}

// MARK: - BoostListRow

// Riga di elenco: altezza minima 56, tile icona 36 con raggio md, titolo
// cardTitle, sottotitolo caption, chevron finale. Stati: normal,
// selected (fondo brand tenue), dragging (overlay + elev-popover),
// disabled (0.4).
struct BoostListRow: View {
    enum RowState { case normal, selected, dragging, disabled }

    let title: String
    var subtitle: String?
    let icon: String
    var tint: Color
    var badges: [BoostBadgeModel]
    var state: RowState
    let action: () -> Void

    init(title: String, subtitle: String? = nil,
         icon: String, tint: Color = DesignColor.brandPrimary,
         badges: [BoostBadgeModel] = [],
         state: RowState = .normal,
         action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.badges = badges
        self.state = state
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSpace.s3) {
                if state == .dragging {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: DesignIcon.sm))
                        .foregroundStyle(DesignColor.textTertiary)
                }
                RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                    .fill(tintBackground)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: DesignIcon.md))
                            .foregroundStyle(tint)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(DesignFont.cardTitle)
                            .foregroundStyle(state == .selected ? DesignColor.brandPrimary : DesignColor.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                            BoostBadge(model: badge)
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(DesignFont.caption)
                            .foregroundStyle(DesignColor.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: DesignIcon.sm))
                    .foregroundStyle(DesignColor.textTertiary)
            }
            .padding(.horizontal, DesignSpace.s3)
            .padding(.vertical, DesignSpace.s2)
            .frame(minHeight: DesignSize.rowMin)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
            .opacity(state == .disabled ? 0.4 : 1)
        }
        .buttonStyle(BoostPressStyle())
        .disabled(state == .disabled)
        .modifier(RowElevation(active: state == .dragging))
    }

    private var tintBackground: Color {
        tint == DesignColor.brandPrimary ? DesignColor.brandPrimarySubtle : tint.opacity(0.12)
    }

    private var rowBackground: Color {
        switch state {
        case .selected: DesignColor.brandPrimarySubtle
        case .dragging: DesignColor.surfaceOverlay
        case .normal, .disabled: .clear
        }
    }
}

private struct RowElevation: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.boostPopoverShadow() } else { content }
    }
}

// MARK: - BoostCard

// Card: raggio lg, padding s4. La superficie alterna (§9): su pagina
// bianca è sunken; su pannello sunken è page con hairline. Selezione =
// bordo interno brand da 1.5. Mai una card dentro un'altra card.
struct BoostCard<Content: View>: View {
    let title: String
    var meta: String?
    var badge: BoostBadgeModel?
    var isSelected: Bool
    var onSunkenSurface: Bool
    var onOpen: (() -> Void)?
    @ViewBuilder var content: () -> Content

    init(title: String, meta: String? = nil,
         badge: BoostBadgeModel? = nil,
         isSelected: Bool = false,
         onSunkenSurface: Bool = false,
         onOpen: (() -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.meta = meta
        self.badge = badge
        self.isSelected = isSelected
        self.onSunkenSurface = onSunkenSurface
        self.onOpen = onOpen
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3 - 2) {
            HStack(alignment: .top, spacing: DesignSpace.s3 - 2) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(DesignFont.cardTitle)
                            .foregroundStyle(DesignColor.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let badge {
                            BoostBadge(model: badge)
                        }
                    }
                    if let meta {
                        Text(meta)
                            .font(DesignFont.caption)
                            .foregroundStyle(DesignColor.textTertiary)
                    }
                }
                Spacer(minLength: 0)
                if onOpen != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: DesignIcon.sm))
                        .foregroundStyle(DesignColor.textTertiary)
                        .frame(width: DesignSize.compact, height: DesignSize.compact)
                }
            }
            content()
        }
        .padding(DesignSpace.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isSelected ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
        .onTapGesture { onOpen?() }
    }

    private var surface: Color {
        onSunkenSurface ? DesignColor.surfacePage : DesignColor.surfaceSunken
    }

    private var borderColor: Color {
        if isSelected { return DesignColor.brandPrimary }
        return onSunkenSurface ? DesignColor.borderSubtle : .clear
    }
}

// MARK: - BoostState

// Un solo pattern per vuoto, caricamento ed errore: glifo, titolo,
// spiegazione, azione. È l'unico posto (con BoostButton) dove può
// vivere una ProgressView.
struct BoostState: View {
    enum Kind { case empty, loading, error }

    let kind: Kind
    var icon: String
    let title: String
    var message: String?
    var action: AnyView?

    init(kind: Kind, icon: String = "archivebox",
         title: String, message: String? = nil, action: AnyView? = nil) {
        self.kind = kind
        self.icon = icon
        self.title = title
        self.message = message
        self.action = action
    }

    var body: some View {
        VStack(spacing: DesignSpace.s2) {
            Group {
                if kind == .loading {
                    ProgressView()
                        .controlSize(.large)
                        .tint(DesignColor.textTertiary)
                } else {
                    Image(systemName: kind == .error ? "exclamationmark.triangle" : icon)
                        .font(.system(size: DesignIcon.xl))
                        .foregroundStyle(kind == .error ? DesignColor.danger : DesignColor.textTertiary)
                }
            }
            .padding(.bottom, 2)
            Text(title)
                .font(DesignFont.cardTitle)
                .foregroundStyle(DesignColor.textPrimary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(DesignFont.caption)
                    .foregroundStyle(DesignColor.textSecondary)
                    .lineSpacing(DesignFont.captionLineSpacing)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            if let action {
                action.padding(.top, 6)
            }
        }
        .padding(.horizontal, DesignSpace.s4)
        .padding(.vertical, DesignSpace.s6)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - BoostToast

struct BoostToastModel: Equatable {
    let id = UUID()
    let text: String
    var role: SemanticRole = .neutral
    var actionTitle: String?
    var actionRun: (() -> Void)?

    static func == (lhs: BoostToastModel, rhs: BoostToastModel) -> Bool {
        lhs.id == rhs.id
    }
}

// Il toast: in basso al centro, 3 secondi, uno alla volta. Esiti da
// comunicare senza interrompere; se l'operazione è annullabile, l'azione
// è "Annulla".
struct BoostToast: View {
    let model: BoostToastModel

    init(_ text: String, role: SemanticRole = .neutral,
         action: (title: String, run: () -> Void)? = nil) {
        model = BoostToastModel(text: text, role: role,
                                actionTitle: action?.title, actionRun: action?.run)
    }

    init(model: BoostToastModel) {
        self.model = model
    }

    var body: some View {
        HStack(spacing: DesignSpace.s2) {
            Image(systemName: model.role == .danger ? "exclamationmark.triangle" : "checkmark.circle.fill")
                .font(.system(size: DesignIcon.sm, weight: .semibold))
                .foregroundStyle(iconInk)
            Text(model.text)
                .font(DesignFont.label)
                .foregroundStyle(DesignColor.textPrimary)
                .lineLimit(2)
            if let actionTitle = model.actionTitle {
                Button {
                    model.actionRun?()
                    BoostToastCenter.shared.dismiss()
                } label: {
                    Text(actionTitle)
                        .font(DesignFont.action)
                        .foregroundStyle(DesignColor.brandPrimary)
                        .padding(.horizontal, DesignSpace.s3)
                        .frame(height: DesignSize.touchMin)
                        .contentShape(Rectangle())
                }
                .buttonStyle(BoostPressStyle())
            }
        }
        .padding(.leading, DesignSpace.s4)
        .padding(.trailing, model.actionTitle == nil ? DesignSpace.s4 : DesignSpace.s1)
        .frame(height: 52)
        .background(DesignColor.surfaceOverlay, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                .strokeBorder(DesignColor.borderDefault, lineWidth: 1)
        }
        .boostPopoverShadow()
    }

    private var iconInk: Color {
        switch model.role {
        case .danger: DesignColor.danger
        case .success: DesignColor.success
        default: DesignColor.textSecondary
        }
    }
}

// Centro toast: un toast alla volta, auto-chiusura a 3 secondi. La radice
// dell'app monta l'host con .boostToastHost().
@MainActor
@Observable
final class BoostToastCenter {
    static let shared = BoostToastCenter()
    private(set) var current: BoostToastModel?
    private var dismissTask: Task<Void, Never>?

    func show(_ text: String, role: SemanticRole = .neutral,
              action: (title: String, run: () -> Void)? = nil) {
        dismissTask?.cancel()
        current = BoostToastModel(text: text, role: role,
                                  actionTitle: action?.title, actionRun: action?.run)
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { current = nil }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { current = nil }
    }
}

private struct BoostToastHost: ViewModifier {
    private var center = BoostToastCenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let model = center.current {
                BoostToast(model: model)
                    .padding(.bottom, DesignSpace.s6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(model.id)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: center.current)
    }
}

extension View {
    func boostToastHost() -> some View { modifier(BoostToastHost()) }
}

// MARK: - BoostSheet

// La struttura unica di tutte le sheet (§4): testata alta 60 con
// hairline sotto, chiusura SEMPRE in alto a destra.
// - .read: sola consultazione o salvataggio continuo → un tasto ✕.
// - .commit: raccoglie una scelta → "Annulla" a sinistra, il verbo
//   dell'azione a destra, disabilitato finché la scelta è vuota.
// Nessuna sheet ha entrambi ✕ e Annulla. Corpo largo al massimo 620.
struct BoostSheet<Content: View>: View {
    enum Mode {
        case read
        case commit(verb: String, enabled: Bool)
    }

    let title: String
    let mode: Mode
    let onDismiss: () -> Void
    var onConfirm: (() -> Void)?
    @ViewBuilder var content: () -> Content

    init(title: String, mode: Mode,
         onDismiss: @escaping () -> Void,
         onConfirm: (() -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.mode = mode
        self.onDismiss = onDismiss
        self.onConfirm = onConfirm
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content()
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignColor.surfaceOverlay)
        // Un toast lanciato da dentro lo sheet deve comparire sopra lo
        // sheet: l'host di RootView sta nella gerarchia coperta sotto.
        .boostToastHost()
    }

    private var header: some View {
        HStack(spacing: DesignSpace.s3 - 2) {
            if case .commit = mode {
                Button("Annulla", action: onDismiss)
                    .font(DesignFont.action)
                    .foregroundStyle(DesignColor.textSecondary)
                    .frame(height: DesignSize.control)
                    .padding(.horizontal, DesignSpace.s3 - 2)
                    .contentShape(Rectangle())
                    .buttonStyle(BoostPressStyle())
            }

            Text(title)
                .font(DesignFont.cardTitle)
                .foregroundStyle(DesignColor.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)

            switch mode {
            case .read:
                BoostIconButton("xmark", action: onDismiss)
            case .commit(let verb, let enabled):
                Button {
                    onConfirm?()
                } label: {
                    Text(verb)
                        .font(DesignFont.action)
                        .foregroundStyle(enabled ? DesignColor.brandPrimary : DesignColor.textTertiary)
                        .opacity(enabled ? 1 : 0.5)
                        .frame(height: DesignSize.control)
                        .padding(.horizontal, DesignSpace.s3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(BoostPressStyle())
                .disabled(!enabled)
            }
        }
        .padding(.leading, DesignSpace.s4)
        .padding(.trailing, DesignSpace.s3)
        .frame(height: 60)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DesignColor.borderSubtle).frame(height: 1)
        }
    }
}
