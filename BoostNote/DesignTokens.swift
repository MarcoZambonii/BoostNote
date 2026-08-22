import SwiftUI

// Dispositivo, non size class: i popover su iPad hanno SEMPRE size class
// compatta, quindi per dimensionare i pannelli fissi serve sapere se si
// è davvero su iPhone. Un solo posto per la domanda, invece di
// UIDevice sparso per le viste.
enum DeviceLayout {
    static var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }
}

// Porta manuale dei token da Claude Design (progetto "BoostNote Design
// System" — tokens/colors.css, spacing.css, radius.css, elevation.css).
// I colori erano definiti in OKLCH: qui sono approssimati in sRGB, dato
// che SwiftUI non offre un init OKLCH diretto su tutte le versioni iOS.
enum DesignColor {
    // Neutrali (grigio caldo)
    static let gray900 = Color(hex: 0x1C1B1A)
    static let gray800 = Color(hex: 0x302E2C)
    static let gray700 = Color(hex: 0x4A4745)
    static let gray600 = Color(hex: 0x635F5C)
    static let gray500 = Color(hex: 0x7D7874)
    static let gray400 = Color(hex: 0x9C9691)
    static let gray300 = Color(hex: 0xBDB6AF)
    static let gray200 = Color(hex: 0xDAD5CE)
    static let gray100 = Color(hex: 0xEBE7E1)
    static let gray50 = Color(hex: 0xF4F2EE)
    static let gray25 = Color(hex: 0xF9F8F6)

    // Brand
    static let blue500 = Color(hex: 0x2F5EFF)
    static let blue50 = Color(hex: 0xEAF0FF)
    static let blue600 = Color(hex: 0x1E44D6)
    static let blue700 = Color(hex: 0x1735AC)

    // Strumenti magici (uno per azione di cerchiatura)
    static let toolWolfram = Color(hex: 0xC1591F)
    static let toolWolframBg = Color(hex: 0xFBEEE3)
    static let toolLatex = Color(hex: 0x9438D6)
    static let toolLatexBg = Color(hex: 0xF3E9FC)
    static let toolExplain = Color(hex: 0x17967E)
    static let toolExplainBg = Color(hex: 0xE7F8F3)
    static let toolSearch = Color(hex: 0xB98A22)
    static let toolSearchBg = Color(hex: 0xFAF1DE)
    static let toolDraw = Color(hex: 0x1F9D55)
    static let toolDrawBg = Color(hex: 0xE7F7EC)

    // MARK: Ruoli semantici (design system 2026-08-16, approvato)
    // Un colore = un significato, in tutta l'app. I colori degli
    // strumenti (toolWolfram, toolLatex, ...) restano un ALTRO spazio,
    // valido solo dentro la nota: qui sotto ci sono i ruoli di interfaccia.
    // - actionPrimary: creare/agire — UNA sola azione blu per schermata.
    // - review: ripasso e memoria (flashcard, Ripassa, spaced repetition).
    // - insight: analisi e progressi. NON è il teal di "Spiega" né il
    //   verde degli esiti: è un petrolio suo, distinguibile da entrambi.
    // - attention: avvisi, limiti dichiarati, azioni di recupero.
    static let actionPrimary = blue500
    static let review = Color(hex: 0x9438D6)
    static let reviewBg = Color(hex: 0xF3E9FC)
    static let insight = Color(hex: 0x1D7F9E)
    static let insightBg = Color(hex: 0xE4F3F8)
    static let attention = Color(hex: 0xC1591F)
    static let attentionBg = Color(hex: 0xFBEEE3)

    static let success = Color(hex: 0x1F9D55)
    static let successBg = Color(hex: 0xE7F7EC)
    static let danger = Color(hex: 0xD63A2E)
    static let dangerBg = Color(hex: 0xFBEAE8)

    // Superfici e testo (tema chiaro)
    static let surfacePage = Color.white
    static let surfaceSunken = gray50
    static let surfaceOverlay = Color.white
    static let borderSubtle = gray100
    static let borderDefault = gray200
    static let textPrimary = gray900
    static let textSecondary = gray600
    static let textTertiary = gray400
    static let textOnBrand = Color.white
    static let brandPrimary = blue500
    static let brandPrimarySubtle = blue50
}

enum DesignSpace {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let s6: CGFloat = 24
    static let s8: CGFloat = 32
}

enum DesignRadius {
    static let sm: CGFloat = 6
    static let md: CGFloat = 10
    static let lg: CGFloat = 14
    static let xl: CGFloat = 20
    static let pill: CGFloat = 999
}

// Scala tipografica CHIUSA del design system (tokens/typography.css):
// dieci ruoli, nessun altro. La regola di scelta sta nel §1 del README
// del kit; `.fontWeight()` dopo un DesignFont è vietato — il peso lo
// porta il ruolo. I titoli sono LEGGERI di proposito (la gerarchia la
// dà la dimensione, non il grassetto): non reintrodurre il semibold.
enum DesignFont {
    static let display      = Font.system(size: 30, weight: .ultraLight)
    static let screenTitle  = Font.system(size: 26, weight: .light)
    static let sectionTitle = Font.system(size: 20, weight: .light)
    static let cardTitle    = Font.system(size: 15, weight: .semibold)
    static let body         = Font.system(size: 15, weight: .regular)
    static let action       = Font.system(size: 13, weight: .semibold)
    static let label        = Font.system(size: 13, weight: .medium)
    static let caption      = Font.system(size: 12, weight: .regular)
    static let micro        = Font.system(size: 10, weight: .semibold)
    static let mono         = Font.system(size: 14, weight: .regular, design: .monospaced)

    // unica eccezione alla scala: quadranti numerici degli strumenti
    // (display della calcolatrice, timer Pomodoro)
    static func readout(size: CGFloat) -> Font {
        .system(size: size, weight: .ultraLight, design: .default)
    }

    // spazio AGGIUNTO fra le righe (.lineSpacing), non line-height
    static let bodyLineSpacing: CGFloat = 3
    static let captionLineSpacing: CGFloat = 2
    static let monoLineSpacing: CGFloat = 2
}

// `.font(.system(size:))` su un'Image NON è tipografia: è dimensione
// icona, e i passi sono quattro — nessun altro.
enum DesignIcon {
    static let sm: CGFloat = 14
    static let md: CGFloat = 17
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
}

// Altezze di controllo (iPad: area di tocco minima 44, sempre).
enum DesignSize {
    static let control: CGFloat = 44   // bottoni, campi, righe tappabili
    static let compact: CGFloat = 38   // SOLO testate di card e pannelli
    static let touchMin: CGFloat = 44  // area di tocco minima, sempre
    static let rowMin: CGFloat = 56    // riga di elenco
}

// Le DUE elevazioni del sistema (tokens/colors.css --elev-popover /
// --elev-sheet): niente altre ombre, niente blur, niente gradienti.
extension View {
    func boostPopoverShadow() -> some View { shadow(color: .black.opacity(0.16), radius: 20, y: 7) }
    func boostSheetShadow() -> some View { shadow(color: .black.opacity(0.28), radius: 30, y: 12) }
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}


// Le tre varianti di bottone dell'app, dagli handoff di design: piena,
// bordata, distruttiva. Esistono per sostituire .borderedProminent e
// .bordered di sistema, che disegnano una CAPSULA e un raggio loro —
// accanto ai blocchi da 10/14 sembravano di un'altra app. Regola unica di
// tutta l'interfaccia: nessuna capsula, raggi solo dai token.
struct BoostButtonStyle: ButtonStyle {
    enum Tone { case filled, outlined, destructive }
    var tone: Tone = .outlined

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignFont.action)
            .foregroundStyle(ink)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(face, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                    .strokeBorder(tone == .filled ? .clear : DesignColor.borderDefault, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }

    private var ink: Color {
        switch tone {
        case .filled: DesignColor.textOnBrand
        case .outlined: DesignColor.textPrimary
        case .destructive: DesignColor.danger
        }
    }

    private var face: Color {
        tone == .filled ? DesignColor.brandPrimary : DesignColor.surfacePage
    }
}

extension ButtonStyle where Self == BoostButtonStyle {
    static var boostFilled: BoostButtonStyle { BoostButtonStyle(tone: .filled) }
    static var boostOutlined: BoostButtonStyle { BoostButtonStyle(tone: .outlined) }
    static var boostDestructive: BoostButtonStyle { BoostButtonStyle(tone: .destructive) }
}


// Selettore a segmenti dell'app: fondo `surface-page`, opzione scelta su
// `brand-primary-subtle` col testo in brand. Sostituisce
// .pickerStyle(.segmented), che porta il grigio e il raggio di iOS e
// accanto ai blocchi da 14 sembra di un'altra app.
struct BoostSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isOn = selection == option.value
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(isOn ? DesignFont.action : DesignFont.label)
                        .foregroundStyle(isOn ? DesignColor.brandPrimary : DesignColor.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: DesignSize.compact)
                        .background(
                            isOn ? DesignColor.brandPrimarySubtle : .clear,
                            in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(DesignColor.surfacePage, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                .strokeBorder(DesignColor.borderSubtle, lineWidth: 1)
        }
    }
}
