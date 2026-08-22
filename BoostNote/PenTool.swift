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
        // L'evidenziatore usa l'inchiostro `.marker` di PencilKit, che
        // si FONDE con ciò che sta sotto invece di coprirlo: la
        // scrittura resta nera e leggibile sotto il giallo, che è come
        // ci si aspetta lavori un evidenziatore. Il prezzo è la punta a
        // scalpello, che cambia spessore a seconda della direzione del
        // tratto — con la penna trasparente non succedeva, ma quella
        // stendeva una velatura SOPRA il testo e lo ingrigiva.
        case .marker: .marker
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

    // Solo la penna può rinunciare alla pressione: l'inchiostro a
    // spessore costante di PencilKit (`.monoline`) è accettato fino a 4
    // punti, che bastano per scrivere ma non per evidenziare — un
    // evidenziatore da 4 punti non evidenzia niente.
    var supportsConstantWidth: Bool { self == .pen }

    // L'inchiostro davvero usato, che dipende dalla pressione scelta.
    func inkType(pressure: Bool) -> PKInkingTool.InkType? {
        guard !pressure, supportsConstantWidth else { return inkType }
        return .monoline
    }

    // A pressione spenta l'intervallo è quello del monoline (0,5-4): con
    // quello della penna lo slider avrebbe mostrato fino a 25 punti che
    // PencilKit avrebbe tagliato in silenzio.
    func widthRange(pressure: Bool) -> ClosedRange<CGFloat> {
        inkType(pressure: pressure)?.validWidthRange ?? widthRange
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

    // Serve SOLO all'anteprima dal vivo del tratto (il livello che
    // disegna mentre la punta è giù): quello compone in modo normale e
    // senza un po' di trasparenza l'evidenziatore coprirebbe il testo
    // finché non si stacca la penna. Il tratto definitivo lo rende
    // PencilKit con l'inchiostro `.marker`, che si fonde da sé.
    static let markerLivePreviewOpacity: CGFloat = 0.4

}

// Curva di risposta alla pressione della penna:
//
//     larghezza = base · (floor + (1 − floor) · force^gamma)
//
// `floor` è lo spessore relativo a tocco leggerissimo (1 = pressione
// ignorata, tratto costante); `gamma` piega la curva: sopra 1 serve
// premere di più perché lo spessore cresca, sotto 1 risponde già ai
// tocchi leggeri. Regolabile dai cursori nel popover della penna per
// la taratura dal vivo; i valori restano in UserDefaults.
enum InkPressure {
    private static let floorKey = "inkPressureFloor"
    private static let gammaKey = "inkPressureGamma"
    // Tarati a mano su iPad dall'utente il 2026-08-14.
    static let defaultFloor: Double = 0.3
    static let defaultGamma: Double = 1.4

    // Letti fino a 240 volte al secondo durante la scrittura: la verità
    // sta in queste variabili, UserDefaults solo al primo accesso e
    // quando i cursori scrivono.
    static var floor: CGFloat = initial(floorKey, defaultFloor) {
        didSet { UserDefaults.standard.set(Double(floor), forKey: floorKey) }
    }
    static var gamma: CGFloat = initial(gammaKey, defaultGamma) {
        didSet { UserDefaults.standard.set(Double(gamma), forKey: gammaKey) }
    }

    private static func initial(_ key: String, _ fallback: Double) -> CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: key) as? Double ?? fallback)
    }

    static func width(base: CGFloat, force: CGFloat) -> CGFloat {
        base * (floor + (1 - floor) * pow(force, gamma))
    }
}

// Fluidità del tratto: distanza minima fra due punti di controllo della
// B-spline, in punti di contenuto. A 240 Hz i campioni ricalcano ogni
// tremolio del polso e la spline, passando vicino a tutti, lo insegue;
// diradandoli la curva smette di inseguire il jitter e lo MEDIA — è la
// levigatura alla Notability, senza filtri che ritardano la punta.
// 0 = nessun diradamento (fedele al polso), 5 = molto morbido ma le
// asole strette delle lettere iniziano ad arrotondarsi.
enum InkSmoothing {
    private static let key = "inkMinPointDistance"
    // Tarata a mano su iPad dall'utente il 2026-08-14.
    static let defaultDistance: Double = 1.5

    static var minPointDistance: CGFloat = CGFloat(
        UserDefaults.standard.object(forKey: key) as? Double ?? defaultDistance
    ) {
        didSet { UserDefaults.standard.set(Double(minPointDistance), forKey: key) }
    }
}

extension PenTool {
    func pkTool(color: Color, width: CGFloat, eraserType: PKEraserTool.EraserType, eraserWidth: CGFloat, pressure: Bool = true) -> PKTool {
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
            guard let inkType = inkType(pressure: pressure) else { return PKInkingTool(.pen, color: UIColor(color), width: width) }
            // Fuori intervallo PencilKit taglia in silenzio: si taglia
            // qui, così il valore mostrato è quello davvero applicato.
            let range = inkType.validWidthRange
            let clamped = min(max(width, range.lowerBound), range.upperBound)
            // Niente alpha a mano sull'evidenziatore: l'inchiostro
            // `.marker` è già translucido e si fonde da sé. Sommarci
            // anche il 40% lo rendeva un alone slavato.
            let inkColor = UIColor(color)
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
        // Coerente col popover della gomma: la parziale è disattivata.
        case .eraser: "Cancella il tratto intero che tocchi."
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
    // Opzionale: chi aggiorna l'app ha un salvataggio senza questa
    // chiave, e la penna deve semplicemente restare a pressione.
    var pressures: [String: Bool]?
}
