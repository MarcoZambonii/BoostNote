import SwiftUI

enum PenTool: CaseIterable, Identifiable {
    case pen
    case marker
    case pencil
    case text
    case eraser
    case lasso
    case pointer

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .pen: "pencil.tip"
        case .marker: "highlighter"
        case .pencil: "pencil"
        case .text: "textformat"
        case .eraser: "eraser"
        case .lasso: "lasso"
        case .pointer: "hand.point.up.left.fill"
        }
    }

    // Strumenti che non devono generare tratti: il tocco (anche con la
    // Pencil) serve solo a scorrere/interagire, non a disegnare.
    var disablesDrawing: Bool {
        self == .text || self == .pointer
    }

    var label: String {
        switch self {
        case .pen: "Penna"
        case .marker: "Evidenziatore"
        case .pencil: "Matita"
        case .text: "Testo"
        case .eraser: "Gomma"
        case .lasso: "Selezione (sposta / cerchia)"
        case .pointer: "Puntatore (scorri anche con la Pencil)"
        }
    }
}
