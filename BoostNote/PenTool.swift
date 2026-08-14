import PencilKit
import SwiftUI

// `String` come raw value serve a salvare colore e spessore per
// strumento in un dizionario unico: con una coppia di proprietà
// @AppStorage per ciascuno sarebbero variabili da tenere allineate a
// mano una per una.
enum PenTool: String, CaseIterable, Identifiable {
    case pen
    case marker
    case text
    case eraser
    case lasso
    case pointer

    var id: Self { self }

    // MARK: - Inchiostro

    // Il tipo PencilKit corrispondente, nil per gli strumenti che non
    // lasciano tratto. È l'unico punto in cui si dichiara cosa sia uno
    // strumento: spessori, default e costruzione del PKTool derivano da
    // qui, così aggiungerne uno nuovo significa aggiungere una riga.
    var inkType: PKInkingTool.InkType? {
        switch self {
        case .pen: .pen
        // L'evidenziatore è una PENNA con inchiostro trasparente: punta
        // tonda, tratto uniforme, nessuna sorpresa in curva.
        //
        // Sarebbe stato meglio `.monoline`, che ha larghezza IDENTICA a
        // qualsiasi pressione (misurato: 12,25 pt da forza 0 a forza 1).
        // Non si può: PencilKit gli accetta larghezze solo fino a 4 punti,
        // e un evidenziatore da 4 punti non evidenzia niente — ne serve
        // una ventina. La penna arriva a 25,66.
        //
        // Il prezzo è che la penna resta un po' sensibile alla pressione.
        // Il testo sotto comunque resta leggibile: misurato con giallo al
        // 40%, un tratto nero coperto resta a 55-79 su 255, cioè grigio
        // scuro — non è lo sbiadimento che si temeva.
        case .marker: .pen
        case .text, .eraser, .lasso, .pointer: nil
        }
    }

    var isInk: Bool { inkType != nil }

    // Intervallo dello slider, chiesto a PencilKit invece che scritto a
    // mano. Gli intervalli fissi di prima erano SBAGLIATI e in modo
    // silenzioso: la matita partiva da 1 ma PencilKit non scende sotto
    // 2,4, l'evidenziatore partiva da 6 contro un minimo di 7,5. Nella
    // parte bassa dello slider il cursore si muoveva e il tratto restava
    // identico, perché il valore veniva riportato al minimo valido — è
    // il motivo per cui "matita ed evidenziatore non funzionano bene".
    //
    // Valori misurati su iOS 26.5:
    //   pen 0,88-25,66 | pencil 2,4-16 | marker 7,5-60 | monoline 0,5-4
    //   fountainPen 1,5-14 | watercolor 10-80 | crayon 10-50
    // Sono diversi per ogni inchiostro: nessun intervallo unico poteva
    // funzionare per tutti.
    var widthRange: ClosedRange<CGFloat> {
        inkType?.validWidthRange ?? 1...30
    }

    // Spessore iniziale. NON si usa `inkType.defaultWidth`: per matita e
    // tratto fisso PencilKit restituisce il MINIMO del loro intervallo
    // (2,4 e 0,5), e una matita a 2,4 è una linea sottile e uniforme —
    // indistinguibile da una penna, che è esattamente com'era prima. La
    // grana della grafite si vede solo con un po' di larghezza: a 3px
    // copre 8px di media contro i 35px di una matita a 12.
    var defaultWidth: CGFloat {
        switch self {
        case .pen: 3
        case .marker: 24
        default: 4
        }
    }

    // Colore di partenza la prima volta che si sceglie lo strumento.
    var defaultColor: Color {
        switch self {
        case .marker: .yellow
        default: .black
        }
    }

    // Trasparenza dell'evidenziatore. Ora che è una penna normale, non
    // si fonde più con quello che c'è sotto: la leggibilità del testo
    // dipende tutta da questo valore. Misurato su testo nero coperto:
    // 0,25 -> 39/255, 0,4 -> 55/255, 0,5 -> 79/255 (grigio chiaro).
    // 0,4 tiene il giallo pieno e il testo scuro.
    static let markerOpacity: CGFloat = 0.4

    func pkTool(color: Color, width: CGFloat, eraserType: PKEraserTool.EraserType, eraserWidth: CGFloat) -> PKTool {
        switch self {
        case .eraser:
            return PKEraserTool(eraserType, width: eraserWidth)
        case .lasso:
            return PKLassoTool()
        case .text, .pointer:
            // Non devono disegnare: inchiostro trasparente e larghezza
            // minima come rete di sicurezza, oltre a drawingPolicy.
            return PKInkingTool(.pen, color: .clear, width: 0.01)
        default:
            guard let inkType else { return PKInkingTool(.pen, color: UIColor(color), width: width) }
            // Fuori intervallo PencilKit taglia in silenzio: si taglia
            // qui, così il valore mostrato è quello davvero applicato.
            let range = inkType.validWidthRange
            let clamped = min(max(width, range.lowerBound), range.upperBound)
            let inkColor = self == .marker
                ? UIColor(color).withAlphaComponent(Self.markerOpacity)
                : UIColor(color)
            return PKInkingTool(inkType, color: inkColor, width: clamped)
        }
    }

    // MARK: - Presentazione

    var systemImage: String {
        switch self {
        case .pen: "pencil.tip"
        case .marker: "highlighter"
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
        case .text: "Testo"
        case .eraser: "Gomma"
        case .lasso: "Selezione (sposta / cerchia)"
        case .pointer: "Puntatore (scorri anche con la Pencil)"
        }
    }

    // Cosa distingue davvero questo strumento dagli altri: serve nel
    // menu, dove sette icone di inchiostri si somigliano tutte.
    var hint: String {
        switch self {
        case .pen: "Tratto pieno e uniforme, sensibile alla pressione."
        case .marker: "Punta tonda: evidenzia senza coprire il testo e senza assottigliarsi in curva."
        case .text: "Aggiunge caselle di testo digitate."
        case .eraser: "Cancella per tratto intero o per pixel."
        case .lasso: "Cerchia per spostare o cancellare una selezione."
        case .pointer: "Disattiva il disegno: scorri e tocca senza scrivere."
        }
    }

    // Gli inchiostri, nell'ordine in cui compaiono nella barra.
    static var inkTools: [PenTool] { allCases.filter(\.isInk) }
}

// Forma su disco delle preferenze per strumento (una sola stringa JSON
// in @AppStorage). Le chiavi sono i rawValue di PenTool.
struct StoredInkSettings: Codable {
    var colors: [String: String]
    var widths: [String: Double]
}
