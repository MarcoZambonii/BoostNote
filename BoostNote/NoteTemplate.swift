import Foundation

enum NoteTemplate: String, CaseIterable, Identifiable, Codable {
    case grid
    case lines
    case cross
    case blank

    var id: Self { self }

    var label: String {
        switch self {
        case .grid: "Quadretti"
        case .lines: "Righe"
        case .cross: "Crocette"
        case .blank: "Bianco"
        }
    }
}
