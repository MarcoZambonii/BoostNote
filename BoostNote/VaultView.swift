import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// Il vault della cartella (corso): l'elenco dei materiali con lo stato
// di lettura pagina per pagina. Passo 1 dell'infrastruttura — qui si
// vede solo ingestione e stato; indice, recupero e generazione dal
// vault arrivano nei passi successivi.
struct VaultView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let folder: StudyFolder

    @State private var showingNotePicker = false
    @State private var showingPDFImporter = false
    @State private var showingWebeepPicker = false
    @State private var importError: String?
    // Rimozione in attesa di conferma: le pagine lette sono lavoro
    // pagato in chiamate API, e prima bastava una voce di menu.
    @State private var documentPendingDelete: VaultDocument?

    private var activity = VaultActivity.shared

    init(folder: StudyFolder) {
        self.folder = folder
    }

    private var documents: [VaultDocument] {
        folder.vaultDocuments.sorted { $0.addedAt < $1.addedAt }
    }

    private var isIngesting: Bool {
        activity.ingestingFolders.contains(folder.id)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    addButtons

                    if documents.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: DesignSpace.s3) {
                            ForEach(documents) { document in
                                documentRow(document)
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(DesignColor.surfacePage)
            .navigationTitle("Vault del corso")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showingNotePicker) {
            VaultNotePicker(folder: folder)
        }
        .sheet(isPresented: $showingWebeepPicker) {
            WebeepFilePickerSheet { data, name in
                addWebeepFile(data: data, name: name)
            }
        }
        .fileImporter(isPresented: $showingPDFImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            importPDFs(result)
        }
        // Binding vero, non `.constant`: con la costante SwiftUI non può
        // scrivere false alla chiusura e una dismissal di sistema
        // (rotazione, cambio scena) lasciava lo stato incoerente.
        .alert("Aggiunta al Vault non riuscita", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert(
            "Rimuovere dal Vault?",
            isPresented: Binding(
                get: { documentPendingDelete != nil },
                set: { if !$0 { documentPendingDelete = nil } }
            ),
            presenting: documentPendingDelete
        ) { document in
            Button("Rimuovi", role: .destructive) {
                documentPendingDelete = nil
                context.delete(document)
            }
            Button("Annulla", role: .cancel) { documentPendingDelete = nil }
        } message: { document in
            Text("“\(document.title)” e le sue \(document.pages.count) pagine lette verranno rimossi dal Vault. Gli studi già generati non vengono toccati.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: DesignSpace.s2) {
                Image(systemName: "archivebox.fill")
                    .foregroundStyle(folder.folderColor.color)
                Text(folder.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DesignColor.textPrimary)
                Spacer()
                if isIngesting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Leggo…")
                            .font(.system(size: 12))
                            .foregroundStyle(DesignColor.textSecondary)
                    }
                } else if !documents.isEmpty {
                    Button {
                        Task { await VaultIngestionService.ensureFresh(for: folder, in: context) }
                    } label: {
                        // Bordata col raggio dei bottoni, non una capsula:
                        // nel Vault le stondature sono una scala sola.
                        Label("Aggiorna", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DesignColor.textPrimary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(DesignColor.surfacePage, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                                    .strokeBorder(DesignColor.borderDefault, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Il Vault è la memoria del corso: tutto il materiale viene letto una volta sola, pagina per pagina, e resta pronto per studi, esercizi e ripassi. Le note restano collegate: quando le modifichi, si rileggono solo le pagine cambiate.")
                .font(.system(size: 12))
                .foregroundStyle(DesignColor.textSecondary)
        }
    }

    private func documentRow(_ document: VaultDocument) -> some View {
        HStack(alignment: .top, spacing: DesignSpace.s3) {
            RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                .fill(DesignColor.brandPrimarySubtle)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: document.kind == .note ? "note.text" : "doc.richtext")
                        .font(.system(size: 15))
                        .foregroundStyle(DesignColor.brandPrimary)
                )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DesignSpace.s2) {
                    Text(document.title.isEmpty ? "Senza titolo" : document.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignColor.textPrimary)
                        .lineLimit(1)
                    if document.kind == .note {
                        Text("Nota collegata")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DesignColor.insight)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DesignColor.insightBg, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
                    }
                    if document.isExamPaper {
                        Text("Tema d'esame")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DesignColor.attention)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DesignColor.attentionBg, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
                    }
                }
                statusLine(document)
            }
            Spacer(minLength: 0)
        }
        .padding(DesignSpace.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
        .contextMenu {
            Button {
                document.isExamPaper.toggle()
            } label: {
                Label(document.isExamPaper ? "Non è un tema d'esame" : "Segna come tema d'esame", systemImage: "doc.questionmark")
            }
            Button(role: .destructive) {
                documentPendingDelete = document
            } label: {
                Label("Rimuovi dal vault", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ document: VaultDocument) -> some View {
        let total = document.pages.count
        let read = document.readCount
        let failed = document.failedCount
        if total == 0 {
            Label("In attesa di lettura…", systemImage: "clock")
                .font(.system(size: 12))
                .foregroundStyle(DesignColor.textSecondary)
        } else if read == total {
            VStack(alignment: .leading, spacing: 4) {
                let characters = document.fullText.count
                Label("\(total) pagine lette · \(characters.formatted()) caratteri", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColor.success)
                // L'indice: gli argomenti che il Vault ha riconosciuto.
                // È la prova visibile che il materiale non è solo
                // archiviato ma capito — e ciò che guiderà il recupero.
                let topics = document.allTopics
                if !topics.isEmpty {
                    Text(topics.prefix(8).joined(separator: " · ") + (topics.count > 8 ? " · +\(topics.count - 8)" : ""))
                        .font(.system(size: 11))
                        .foregroundStyle(DesignColor.brandPrimary)
                        .lineLimit(2)
                } else if isIngesting {
                    Text("Costruisco l'indice degli argomenti…")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignColor.textSecondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if isIngesting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "clock").font(.system(size: 12))
                    }
                    Text("\(read) di \(total) pagine lette")
                        .font(.system(size: 12))
                }
                .foregroundStyle(DesignColor.attention)
                if failed > 0 {
                    Text("\(failed) pagine non lette: si ritenteranno al prossimo aggiornamento.")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignColor.textSecondary)
                }
            }
        }
    }

    private var addButtons: some View {
        HStack(spacing: DesignSpace.s3) {
            addAction("Aggiungi PDF", icon: "doc.badge.plus", filled: true) { showingPDFImporter = true }
            addAction("Aggiungi nota", icon: "note.text.badge.plus") { showingNotePicker = true }
            addAction("Da WeBeep", icon: "graduationcap") { showingWebeepPicker = true }
        }
    }

    private func addAction(_ title: String, icon: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 15))
                Text(title).font(.system(size: 13.5, weight: .semibold))
            }
            .foregroundStyle(filled ? DesignColor.textOnBrand : DesignColor.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                filled ? DesignColor.brandPrimary : DesignColor.surfacePage,
                in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                    .strokeBorder(filled ? .clear : DesignColor.borderDefault, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func addWebeepFile(data: Data, name: String) {
        // Solo PDF, per ora: stessa regola della creazione studio. La
        // firma "%PDF" in testa è più affidabile dell'estensione.
        let isPDF = name.lowercased().hasSuffix(".pdf") || data.prefix(4).elementsEqual([0x25, 0x50, 0x44, 0x46])
        guard isPDF else {
            importError = "\(name): per ora il Vault legge solo PDF."
            return
        }
        let title = (name as NSString).deletingPathExtension
        let document = VaultIngestionService.addPDF(title: title, data: data, to: folder, in: context)
        document.isExamPaper = StudioCreateFlowView.looksLikeExamPaper(title)
    }

    private var emptyState: some View {
        VStack(spacing: DesignSpace.s2) {
            Image(systemName: "archivebox")
                .font(.system(size: 30))
                .foregroundStyle(DesignColor.textTertiary)
            Text("Il Vault è vuoto")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)
            Text("Metti qui tutto il materiale del corso: note, dispense, temi d'esame, file WeBeep. Verrà letto una volta e resterà pronto per studi, esercizi e ripassi.")
                .font(.system(size: 12))
                .foregroundStyle(DesignColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSpace.s6)
    }

    private func importPDFs(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            for url in urls {
                let secured = url.startAccessingSecurityScopedResource()
                defer { if secured { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    importError = "Non riesco a leggere \(url.lastPathComponent)."
                    continue
                }
                let title = url.deletingPathExtension().lastPathComponent
                let document = VaultIngestionService.addPDF(title: title, data: data, to: folder, in: context)
                // Stessa euristica del flusso di creazione studio.
                document.isExamPaper = StudioCreateFlowView.looksLikeExamPaper(title)
            }
        }
    }
}

// Selettore dei documenti del Vault per il flusso "Crea studio":
// raggruppa per corso (cartella), multi-selezione, e mostra lo stato di
// lettura — un documento non ancora letto si può scegliere, ma è giusto
// vederlo prima.
struct VaultSourcePicker: View {
    @Environment(\.dismiss) private var dismiss
    let alreadyPicked: Set<UUID>
    var onPicked: ([StudySourceMaterial]) -> Void

    @Query(sort: \StudyFolder.name) private var folders: [StudyFolder]
    @State private var selected: Set<UUID> = []

    private var foldersWithVault: [StudyFolder] {
        folders.filter { !$0.vaultDocuments.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Group {
                if foldersWithVault.isEmpty {
                    VStack(spacing: DesignSpace.s2) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 30))
                            .foregroundStyle(DesignColor.textTertiary)
                        Text("Nessun Vault con materiale")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Apri una cartella di Studio e aggiungi note, PDF o file WeBeep al suo Vault: da lì gli studi si creano senza rileggere niente.")
                            .font(.system(size: 12))
                            .foregroundStyle(DesignColor.textTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(foldersWithVault) { folder in
                            Section {
                                ForEach(folder.vaultDocuments.sorted { $0.addedAt < $1.addedAt }) { document in
                                    documentRow(document)
                                }
                            } header: {
                                Label(folder.name, systemImage: "archivebox.fill")
                                    .foregroundStyle(folder.folderColor.color)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Dal Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aggiungi (\(selected.count))") {
                        confirm()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private func documentRow(_ document: VaultDocument) -> some View {
        let isPicked = alreadyPicked.contains(document.id)
        Button {
            guard !isPicked else { return }
            if selected.contains(document.id) {
                selected.remove(document.id)
            } else {
                selected.insert(document.id)
            }
        } label: {
            HStack(spacing: DesignSpace.s3) {
                Image(systemName: selected.contains(document.id) || isPicked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(document.id) ? DesignColor.brandPrimary : DesignColor.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.title.isEmpty ? "Senza titolo" : document.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isPicked ? DesignColor.textTertiary : DesignColor.textPrimary)
                    statusText(document)
                }
                Spacer()
                if document.isExamPaper {
                    Text("Tema d'esame")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignColor.attention)
                }
            }
        }
        .disabled(isPicked)
    }

    @ViewBuilder
    private func statusText(_ document: VaultDocument) -> some View {
        let total = document.pages.count
        let read = document.readCount
        if total > 0 && read == total {
            Text("\(total) pagine pronte")
                .font(.system(size: 11))
                .foregroundStyle(DesignColor.success)
        } else {
            Text(total == 0 ? "Non ancora letto" : "Letto in parte (\(read) di \(total)): verrà aggiornato alla creazione")
                .font(.system(size: 11))
                .foregroundStyle(DesignColor.attention)
        }
    }

    private func confirm() {
        var picked: [StudySourceMaterial] = []
        for folder in foldersWithVault {
            for document in folder.vaultDocuments where selected.contains(document.id) {
                picked.append(StudySourceMaterial(
                    kind: .vault,
                    title: document.title,
                    subtitle: folder.name,
                    isExamPaper: document.isExamPaper,
                    vaultDocumentID: document.id
                ))
            }
        }
        onPicked(picked)
        dismiss()
    }
}

// Selettore delle note da collegare al vault: mostra solo quelle non
// ancora presenti.
private struct VaultNotePicker: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let folder: StudyFolder

    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]

    private var availableNotes: [Note] {
        let linked = Set(folder.vaultDocuments.compactMap(\.noteID))
        return notes.filter { !linked.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List(availableNotes) { note in
                Button {
                    VaultIngestionService.addNote(note, to: folder, in: context)
                    dismiss()
                } label: {
                    HStack(spacing: DesignSpace.s3) {
                        Image(systemName: "note.text")
                            .foregroundStyle(DesignColor.brandPrimary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title.isEmpty ? "Senza titolo" : note.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(DesignColor.textPrimary)
                            Text("\(note.pages.count) pagine")
                                .font(.system(size: 11))
                                .foregroundStyle(DesignColor.textTertiary)
                        }
                    }
                }
            }
            .navigationTitle("Collega una nota")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
    }
}
