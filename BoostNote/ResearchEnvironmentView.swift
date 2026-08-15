import SwiftUI

// Ambiente "Ricerca" a tutta pagina (rail sinistra): stessa ricerca
// (arXiv e riviste) del pannello Strumenti, qui come schermata principale.
struct ResearchEnvironmentView: View {
    @Binding var selectedNote: Note?
    @State private var model = PaperSearchModel()

    var body: some View {
        NavigationStack {
            ResearchContentView(model: model, onImported: { note in selectedNote = note })
                .navigationTitle("Ricerca")
        }
    }
}
