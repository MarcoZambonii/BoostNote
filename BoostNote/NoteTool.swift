import Foundation

enum NoteTool: String, CaseIterable, Identifiable {
    case todo
    case pomodoro
    case calculator
    case research
    case graphing
    case wolfram
    case document

    var id: Self { self }

    var label: String {
        switch self {
        case .todo: "To-Do List"
        case .pomodoro: "Pomodoro"
        case .calculator: "Calcolatrice"
        case .research: "Ricerca"
        case .graphing: "Grafici"
        case .wolfram: "Wolfram Alpha"
        case .document: "Documento"
        }
    }

    // Descrizione breve mostrata nel pannello a cascata quando lo strumento è selezionato.
    var toolDescription: String {
        switch self {
        case .todo: "Una lista di cose da fare, direttamente sul foglio."
        case .pomodoro: "Un timer Pomodoro per restare concentrato senza uscire dalla nota."
        case .calculator: "Calcolatrice rapida per i calcoli al volo."
        case .research: "Cerca paper accademici su arXiv e aggiungili alla nota."
        case .graphing: "Grafico interattivo (GeoGebra): pan, zoom, traccia — non solo un disegno."
        case .wolfram: "Risolvi espressioni ed equazioni con Wolfram Alpha."
        case .document: "Importa un PDF come pagina del foglio o come widget spostabile."
        }
    }

    var systemImage: String {
        switch self {
        case .todo: "checklist"
        case .pomodoro: "timer"
        case .calculator: "plusminus.circle"
        case .research: "globe.americas"
        case .graphing: "chart.xyaxis.line"
        case .wolfram: "function"
        case .document: "doc.text"
        }
    }

    // I widget si inseriscono direttamente sul foglio; gli altri strumenti
    // restano pannelli standalone.
    var isInsertableWidget: Bool {
        switch self {
        case .todo, .pomodoro, .graphing, .wolfram: true
        case .calculator, .research, .document: false
        }
    }

    var widgetKind: NoteWidgetKind? {
        switch self {
        case .todo: .todo
        case .pomodoro: .pomodoro
        case .graphing: .graph
        case .wolfram: .wolfram
        default: nil
        }
    }
}
