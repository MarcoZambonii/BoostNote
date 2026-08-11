import SwiftUI

// Le azioni della "penna magica": si sceglie l'azione, poi si cerchia
// un'espressione scritta a mano sul foglio per attivarla.
enum MagicAction: String, CaseIterable, Identifiable {
    case wolfram, draw, latex, explain, search

    var id: Self { self }

    var label: String {
        switch self {
        case .wolfram: "Wolfram Alpha"
        case .draw: "Disegna"
        case .latex: "Genera LaTeX"
        case .explain: "Spiega"
        case .search: "Cerca"
        }
    }

    var subtitle: String {
        switch self {
        case .wolfram: "Risolvi"
        case .draw: "Traccia il grafico"
        case .latex: "Converti in formula"
        case .explain: "Spiegazione passo passo"
        case .search: "Cerca sul web"
        }
    }

    var systemImage: String {
        switch self {
        case .wolfram: "function"
        case .draw: "waveform.path.ecg"
        case .latex: "textformat.subscript"
        case .explain: "sparkles"
        case .search: "magnifyingglass"
        }
    }

    var color: Color {
        switch self {
        case .wolfram: DesignColor.toolWolfram
        case .draw: DesignColor.toolDraw
        case .latex: DesignColor.toolLatex
        case .explain: DesignColor.toolExplain
        case .search: DesignColor.toolSearch
        }
    }

    var backgroundColor: Color {
        switch self {
        case .wolfram: DesignColor.toolWolframBg
        case .draw: DesignColor.toolDrawBg
        case .latex: DesignColor.toolLatexBg
        case .explain: DesignColor.toolExplainBg
        case .search: DesignColor.toolSearchBg
        }
    }
}
