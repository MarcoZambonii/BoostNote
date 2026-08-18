import SwiftUI

// Ambiente "Ricerca" a tutta pagina (rail sinistra): stessa ricerca
// (arXiv e riviste) del pannello Strumenti, qui come schermata principale.
struct ResearchEnvironmentView: View {
    @Binding var selectedNote: Note?
    // Su iPad la vista è il dettaglio della split view e porta con sé il
    // proprio NavigationStack; su iPhone viene SPINTA su uno stack già
    // esistente, e annidarne un secondo romperebbe il pulsante indietro.
    var embedsNavigationStack: Bool = true
    @State private var model = PaperSearchModel()

    var body: some View {
        if embedsNavigationStack {
            NavigationStack { content }
        } else {
            content
        }
    }

    private var content: some View {
        ResearchContentView(model: model, onImported: { note in selectedNote = note })
            .navigationTitle("Ricerca")
    }
}
