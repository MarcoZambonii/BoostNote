import SwiftUI
import SwiftData

// Ambiente "Studio": occupa TUTTA l'area di dettaglio.
//
// La colonna centrale con l'elenco degli studi non esiste più: l'app
// aveva due barre laterali sovrapposte (quella principale e quella
// interna), che rubavano larghezza al contenuto e obbligavano a imparare
// due modi diversi di navigare. Ora gli studi stanno nell'albero della
// barra principale insieme alle loro cartelle e ai loro moduli — vedi
// StudioSidebarSection — e qui resta solo ciò che si sta guardando.
struct StudioEnvironmentView: View {
    @Environment(\.modelContext) private var context

    @Binding var selectedStudy: Study?
    @Binding var selectedModule: StudyModule?
    @Binding var showingProgress: Bool
    @Binding var showingCreate: Bool

    @Query(sort: \Study.updatedAt, order: .reverse) private var studies: [Study]

    var body: some View {
        Group {
            if showingProgress {
                StudioProgressView(studies: studies, onBack: { showingProgress = false })
            } else if showingCreate {
                StudioCreateFlowView(
                    onCancel: { showingCreate = false },
                    onCreated: { study in
                        selectedStudy = study
                        selectedModule = nil
                        showingCreate = false
                    }
                )
            } else if selectedStudy == nil {
                StudioHomeView(
                    selectedStudy: $selectedStudy,
                    showingProgress: $showingProgress,
                    onCreateStudy: { showingCreate = true }
                )
            } else if let study = selectedStudy {
                StudyDetailView(
                    study: study,
                    openModule: $selectedModule,
                    onBack: {
                        selectedStudy = nil
                        selectedModule = nil
                    },
                    onDelete: { delete(study) }
                )
                .id(study.persistentModelID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignColor.surfacePage)
    }

    private func delete(_ study: Study) {
        selectedStudy = nil
        selectedModule = nil
        context.delete(study)
    }
}
