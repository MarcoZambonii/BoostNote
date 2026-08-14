import Foundation

// Gli strumenti della nota vivono TUTTI nel pannello laterale destro
// (persistente, chiudibile), non più come widget flottanti sul foglio:
// un'unica interazione coerente invece di due nature diverse.
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
        case .todo: "Una lista di cose da fare, a fianco della nota."
        case .pomodoro: "Un timer Pomodoro per restare concentrato senza uscire dalla nota."
        case .calculator: "Calcolatrice rapida per i calcoli al volo."
        case .research: "Cerca paper accademici su arXiv e aggiungili alla nota."
        case .graphing: "Traccia il grafico di una funzione mentre studi."
        case .wolfram: "Risolvi espressioni ed equazioni con Wolfram Alpha."
        case .document: "Apri un PDF da consultare a fianco mentre scrivi."
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
}
