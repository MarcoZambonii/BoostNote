import Foundation

// Una casella di testo posizionata liberamente sul foglio della nota,
// in coordinate del contenuto (non dello schermo).
struct NoteTextBox: Identifiable, Codable, Equatable {
    var id = UUID()
    var x: Double
    var y: Double
    var width: Double = 220
    var text: String = ""
}
