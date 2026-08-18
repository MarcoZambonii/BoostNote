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

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
