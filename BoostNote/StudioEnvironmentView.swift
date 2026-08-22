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

    // Cartella da cui precompilare il flusso di creazione ("Crea da
    // questo Vault"): materia e materiali già pronti.
    @State private var createPrefillFolder: StudyFolder?
    // Argomenti su cui puntare, arrivati dall'analisi dei progressi.
    @State private var createPrefillTopics: [String] = []

    var body: some View {
        Group {
            if showingProgress {
                StudioProgressView(
                    studies: studies,
                    onBack: { showingProgress = false },
                    onGenerateWeak: { folder, topics in
                        createPrefillFolder = folder
                        createPrefillTopics = topics
                        showingProgress = false
                        showingCreate = true
                    }
                )
            } else if showingCreate {
                StudioCreateFlowView(
                    prefillFolder: createPrefillFolder,
                    prefillTopics: createPrefillTopics,
                    // Recupero mirato: solo esercizi. Un riassunto sugli
                    // argomenti che già sbagli non aggiunge niente.
                    prefillKinds: createPrefillTopics.isEmpty ? nil : [.exercises],
                    onCancel: {
                        showingCreate = false
                        createPrefillFolder = nil
                        createPrefillTopics = []
                    },
                    onCreated: { study in
                        selectedStudy = study
                        selectedModule = nil
                        showingCreate = false
                        createPrefillFolder = nil
                        createPrefillTopics = []
                    }
                )
                .id(createPrefillTopics.joined(separator: "|"))
            } else if selectedStudy == nil {
                StudioHomeView(
                    selectedStudy: $selectedStudy,
                    showingProgress: $showingProgress,
                    onCreateStudy: { folder in
                        createPrefillFolder = folder
                        showingCreate = true
                    }
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
        // Una generazione in corso va annullata PRIMA di eliminare: il
        // suo task, tornando sul MainActor, scriverebbe stato su moduli
        // eliminati (le guardie nel servizio coprono la finestra residua).
        StudioGenerationService.cancelGeneration(for: study.id)
        selectedStudy = nil
        selectedModule = nil
        context.delete(study)
    }
}
