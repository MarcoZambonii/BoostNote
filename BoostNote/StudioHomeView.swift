import SwiftUI
import SwiftData

// Pagina iniziale dell'ambiente Studio: si apre toccando "Studio" nella
// barra laterale e mostra, nell'area principale, l'azione per creare uno
// studio e sotto quelli che già esistono, raggruppati per cartella.
//
// Sostituisce l'albero degli studi che stava in fondo alla barra
// laterale: cliccare in alto e trovare il contenuto in basso era
// incoerente, e l'intestazione si era riempita di quattro icone che
// nessuno avrebbe indovinato. Qui le azioni sono grandi e nominate, e i
// contenuti stanno dove si guarda dopo aver cliccato.
struct StudioHomeView: View {
    @Environment(\.modelContext) private var context

    @Binding var selectedStudy: Study?
    @Binding var showingProgress: Bool
    // Con una cartella: il flusso parte precompilato dal suo Vault.
    var onCreateStudy: (StudyFolder?) -> Void

    @Query(sort: \StudyFolder.name) private var folders: [StudyFolder]
    @Query(sort: \Study.updatedAt, order: .reverse) private var studies: [Study]

    @State private var folderSheet: StudyFolderSheetMode?
    @State private var vaultFolder: StudyFolder?
    @State private var renamingStudy: Study?
    @State private var renameText = ""

    private var looseStudies: [Study] { studies.filter { $0.folder == nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpace.s8) {
                header

                // Le cartelle si mostrano anche SENZA studi: da quando
                // ospitano il vault dei materiali, una cartella vuota di
                // studi è comunque un corso con il suo menu.
                if studies.isEmpty && folders.isEmpty {
                    emptyState
                } else {
                    // Ogni cartella è una CARD DEL CORSO: il Vault in
                    // testa (documenti e stato di lettura), gli studi
                    // sotto come figli dichiarati del materiale — design
                    // scelto dall'utente su mock (2026-08-15).
                    ForEach(folders) { folder in
                        courseCard(folder)
                    }
                    if !looseStudies.isEmpty {
                        studySection(
                            title: folders.isEmpty ? "I tuoi studi" : "Senza cartella",
                            icon: "tray",
                            tint: DesignColor.textTertiary,
                            studies: looseStudies,
                            folder: nil
                        )
                    }
                }
            }
            .padding(DesignSpace.s6)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(DesignColor.surfacePage)
        .sheet(item: $folderSheet) { mode in
            StudyFolderEditSheet(mode: mode) { name, color, mode in
                saveFolder(name: name, color: color, mode: mode)
            }
        }
        .sheet(item: $vaultFolder) { folder in
            VaultView(folder: folder)
        }
        .alert("Rinomina studio", isPresented: renameAlertPresented) {
            TextField("Nome", text: $renameText)
            Button("Annulla", role: .cancel) { renamingStudy = nil }
            Button("Salva") { applyRename() }
        }
    }

    // Titolo a sinistra, azioni di CORNICE a destra: creare un Vault e
    // guardare i progressi non sono l'azione principale della pagina —
    // lo sono i Vault che già esistono, con i loro studi. Prima una card
    // blu a tutta larghezza gridava "Crea nuovo studio" sopra ogni cosa,
    // e portava a un flusso che poteva anche non passare dal Vault.
    private var header: some View {
        HStack(alignment: .top, spacing: DesignSpace.s4) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Studio")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(DesignColor.textPrimary)
                    Image(systemName: "graduationcap.fill")
                        .foregroundStyle(DesignColor.brandPrimary)
                }
                Text(subtitleText)
                    .font(.system(size: 14))
                    .foregroundStyle(DesignColor.textTertiary)
            }
            Spacer(minLength: 0)
            HStack(spacing: DesignSpace.s2) {
                headerButton(title: "Analisi progressi", icon: "chart.bar.xaxis", tint: DesignColor.insight) {
                    showingProgress = true
                }
                headerButton(title: "Nuovo Vault", icon: "plus", tint: DesignColor.brandPrimary) {
                    folderSheet = .new(parent: nil)
                }
            }
        }
    }

    private var subtitleText: String {
        if folders.isEmpty {
            return "Crea un Vault per corso: il materiale viene letto una volta e diventa la base di studi, esercizi e ripassi."
        }
        let documents = folders.reduce(0) { $0 + $1.vaultDocuments.count }
        var parts = ["\(folders.count) Vault", "\(documents) document\(documents == 1 ? "o" : "i")"]
        if !studies.isEmpty {
            parts.append("\(studies.count) stud\(studies.count == 1 ? "io" : "i")")
            parts.append("\(totalExercises) esercizi generati")
        }
        return parts.joined(separator: " · ")
    }

    private func headerButton(title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, DesignSpace.s3)
                .padding(.vertical, DesignSpace.s2)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var totalExercises: Int {
        studies.reduce(0) { partial, study in
            partial + study.sortedModules
                .filter { $0.kind == .exercises && $0.status == .ready }
                .reduce(0) { $0 + ($1.decodeContent(ExerciseSetContent.self)?.exercises.count ?? 0) }
        }
    }

    // Senza Vault non c'è niente da generare: lo stato vuoto porta a
    // creare il primo, non a un flusso di studio che non avrebbe fonti.
    private var emptyState: some View {
        VStack(spacing: DesignSpace.s3) {
            Image(systemName: "archivebox")
                .font(.system(size: 36))
                .foregroundStyle(DesignColor.textTertiary)
            Text("Nessun Vault, per ora")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)
            Text("Un Vault per corso: ci metti dentro note, dispense, temi d'esame e file WeBeep. Vengono letti una volta e restano pronti per generare riassunti, esercizi e flashcard senza rileggere niente.")
                .font(.system(size: 13))
                .foregroundStyle(DesignColor.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                folderSheet = .new(parent: nil)
            } label: {
                Label("Crea il primo Vault", systemImage: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignColor.textOnBrand)
                    .padding(.horizontal, DesignSpace.s5)
                    .padding(.vertical, DesignSpace.s3)
                    .background(DesignColor.brandPrimary, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, DesignSpace.s2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSpace.s8)
    }

    private func studySection(title: String, icon: String, tint: Color, studies: [Study], folder: StudyFolder?) -> some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            HStack(spacing: DesignSpace.s2) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(tint)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(DesignColor.textSecondary)
                Text("\(studies.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignColor.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(DesignColor.surfaceSunken, in: Capsule())
                Spacer()
                if let folder {
                    // Accesso rapido al vault: se ha già materiale si vede
                    // anche fuori dal menu.
                    if !folder.vaultDocuments.isEmpty {
                        Button {
                            vaultFolder = folder
                        } label: {
                            Label("\(folder.vaultDocuments.count) nel Vault", systemImage: "archivebox.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(DesignColor.brandPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(DesignColor.brandPrimarySubtle, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Menu {
                        Button {
                            vaultFolder = folder
                        } label: {
                            Label("Vault del corso", systemImage: "archivebox")
                        }
                        Button {
                            folderSheet = .edit(folder)
                        } label: {
                            Label("Rinomina / colore", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            context.delete(folder)
                        } label: {
                            Label("Elimina Vault e cartella", systemImage: "trash")
                        }
                        Text("Gli studi dentro non vengono eliminati.")
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DesignColor.textTertiary)
                    }
                }
            }

            if studies.isEmpty {
                Text("Nessuno studio in questa cartella. Dal menu ⋯ apri il Vault del corso: il materiale viene letto una volta e resta pronto per studi, esercizi e ripassi.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColor.textTertiary)
                    .padding(.vertical, DesignSpace.s2)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: DesignSpace.s4)], spacing: DesignSpace.s4) {
                    ForEach(studies) { study in
                        studyCard(study)
                    }
                }
            }
        }
    }

    // MARK: - Card del corso (Vault + studi)

    private func courseCard(_ folder: StudyFolder) -> some View {
        let documents = folder.vaultDocuments.sorted { $0.addedAt < $1.addedAt }
        let folderStudies = folder.sortedStudies
        let isIngesting = VaultActivity.shared.ingestingFolders.contains(folder.id)

        return VStack(alignment: .leading, spacing: 0) {
            // Testata: identità del corso, stato del Vault, azioni.
            HStack(spacing: DesignSpace.s3) {
                RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                    .fill(folder.folderColor.color.opacity(0.14))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(folder.folderColor.color)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DesignColor.textPrimary)
                    Text(vaultSubtitle(for: documents))
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColor.textTertiary)
                }
                Spacer()
                if isIngesting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Leggo…")
                            .font(.system(size: 12))
                            .foregroundStyle(DesignColor.textTertiary)
                    }
                } else if !documents.isEmpty {
                    // Una porta sola per il materiale: "Gestisci" apre il
                    // Vault, dove si vede l'elenco e si aggiorna. Prima
                    // c'erano una ⓘ per sbirciare e un "Aggiorna" a
                    // parte: due mezze porte invece di una intera.
                    Button {
                        vaultFolder = folder
                    } label: {
                        Label("Gestisci Vault", systemImage: "archivebox")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Menu {
                    Button {
                        folderSheet = .edit(folder)
                    } label: {
                        Label("Rinomina / colore", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        context.delete(folder)
                    } label: {
                        Label("Elimina Vault e cartella", systemImage: "trash")
                    }
                    Text("Gli studi dentro non vengono eliminati.")
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignColor.textTertiary)
                        .frame(width: 28, height: 28)
                }
            }
            .padding(DesignSpace.s4)

            // Il materiale è CONTESTO, non contenuto: una riga sola con
            // il pulsantino che apre l'elenco (richiesta esplicita
            // dell'utente — meno peso visivo al Vault, il protagonista
            // sono gli studi).
            if documents.isEmpty {
                Button {
                    vaultFolder = folder
                } label: {
                    Label("Aggiungi il materiale del corso", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DesignColor.brandPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignSpace.s3)
                        .background(
                            RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                                .strokeBorder(DesignColor.borderDefault, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DesignSpace.s4)
            }

            // Gli studi del corso: qui sta il peso visivo.
            VStack(alignment: .leading, spacing: DesignSpace.s3) {
                HStack(spacing: DesignSpace.s2) {
                    Text(documents.isEmpty ? "STUDI" : "STUDI GENERATI DAL VAULT")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(DesignColor.textTertiary)
                    Spacer()
                    if !folderStudies.isEmpty, !documents.isEmpty {
                        // È L'azione del corso: pieno, non sottotono —
                        // ora che dalla testata della pagina è sparito il
                        // "Crea nuovo studio", la generazione parte da
                        // qui, cioè da un Vault preciso.
                        Button {
                            onCreateStudy(folder)
                        } label: {
                            Label("Nuovo studio dal Vault", systemImage: "sparkles")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DesignColor.textOnBrand)
                                .padding(.horizontal, DesignSpace.s4)
                                .padding(.vertical, DesignSpace.s2)
                                .background(DesignColor.brandPrimary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if folderStudies.isEmpty {
                    emptyStudiesArea(folder, documents: documents)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: DesignSpace.s4)], spacing: DesignSpace.s4) {
                        ForEach(folderStudies) { study in
                            studyCard(study, in: folder, background: DesignColor.surfacePage)
                        }
                    }
                }
            }
            .padding(DesignSpace.s4)
        }
        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
    }

    private func vaultSubtitle(for documents: [VaultDocument]) -> String {
        guard !documents.isEmpty else { return "Vault del corso · vuoto" }
        let pages = documents.reduce(0) { $0 + $1.readCount }
        var parts = [
            "Vault del corso",
            "\(documents.count) document\(documents.count == 1 ? "o" : "i")",
            "\(pages) pagine lette"
        ]
        if let last = documents.compactMap(\.lastIngestedAt).max() {
            parts.append("aggiornato \(last.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func vaultDocChipStatus(_ document: VaultDocument) -> some View {
        let pending = document.pendingCount
        let failed = document.failedCount
        let read = document.readCount
        if document.pages.isEmpty {
            Text("In attesa di lettura…")
                .font(.system(size: 11))
                .foregroundStyle(DesignColor.textTertiary)
        } else if pending > 0 {
            Label("\(pending) pagine da leggere", systemImage: "clock")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignColor.attention)
        } else if failed > 0 {
            Label("\(read) lette · \(failed) non riuscite", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignColor.attention)
        } else {
            Label("\(read) pagine lette", systemImage: "checkmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignColor.success)
        }
    }

    private func emptyStudiesArea(_ folder: StudyFolder, documents: [VaultDocument]) -> some View {
        let readPages = documents.reduce(0) { $0 + $1.readCount }
        return VStack(spacing: DesignSpace.s2) {
            Text("Nessuno studio ancora")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)
            Text(readPages > 0
                 ? "Il Vault è pronto: \(readPages) pagine già lette. Genera il primo studio quando vuoi — il materiale non verrà riletto."
                 : "Aggiungi il materiale del corso al Vault, oppure crea uno studio partendo dalle note.")
                .font(.system(size: 12))
                .foregroundStyle(DesignColor.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if readPages > 0 {
                Button {
                    onCreateStudy(folder)
                } label: {
                    Label("Crea da questo Vault", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignColor.brandPrimary)
                        .padding(.horizontal, DesignSpace.s4)
                        .padding(.vertical, DesignSpace.s2 + 2)
                        .background(DesignColor.brandPrimarySubtle, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(DesignSpace.s4)
        .background(
            RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                .strokeBorder(DesignColor.borderDefault, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }

    // Quante pagine del Vault sono cambiate o arrivate DOPO l'ultima
    // generazione dello studio: è la spia "rigenera, c'è materiale
    // nuovo". nil se lo studio non nasce dal Vault.
    private func vaultNewPages(for study: Study, in folder: StudyFolder) -> Int? {
        let ids = Set(study.sources.compactMap(\.vaultDocumentID))
        guard !ids.isEmpty else { return nil }
        let documents = folder.vaultDocuments.filter { ids.contains($0.id) }
        guard !documents.isEmpty else { return nil }
        var count = 0
        for document in documents {
            for page in document.pages {
                if page.status == .pending {
                    count += 1
                } else if let readAt = page.readAt, readAt > study.updatedAt {
                    count += 1
                }
            }
        }
        return count
    }

    private func studyCard(_ study: Study, in folder: StudyFolder? = nil, background: Color = DesignColor.surfaceSunken) -> some View {
        Button {
            selectedStudy = study
            showingProgress = false
        } label: {
            VStack(alignment: .leading, spacing: DesignSpace.s3) {
                HStack(spacing: DesignSpace.s3) {
                    RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                        .fill(DesignColor.brandPrimarySubtle)
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "book.closed.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(DesignColor.brandPrimary)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(study.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesignColor.textPrimary)
                            .lineLimit(1)
                        Text(study.updatedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 11))
                            .foregroundStyle(DesignColor.textTertiary)
                    }
                    Spacer(minLength: 0)
                }

                // I moduli come pastiglie con la loro icona: si capisce a
                // colpo d'occhio cosa contiene lo studio senza aprirlo.
                if !study.sortedModules.isEmpty {
                    HStack(spacing: DesignSpace.s2) {
                        ForEach(study.sortedModules) { module in
                            if let kind = module.kind {
                                HStack(spacing: 4) {
                                    Image(systemName: kind.systemImage)
                                        .font(.system(size: 10, weight: .medium))
                                    if module.status == .failed {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 8))
                                    } else if module.status == .generating {
                                        ProgressView().controlSize(.mini)
                                    }
                                }
                                .foregroundStyle(module.status == .failed ? DesignColor.danger : kind.color)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(
                                    (module.status == .failed ? DesignColor.danger : kind.color).opacity(0.1),
                                    in: Capsule()
                                )
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }

                // Freschezza rispetto al Vault: "al passo" o quante
                // pagine nuove aspettano una rigenerazione.
                if let folder, let newPages = vaultNewPages(for: study, in: folder) {
                    HStack(spacing: 4) {
                        Image(systemName: newPages == 0 ? "checkmark.shield" : "clock")
                            .font(.system(size: 10, weight: .medium))
                        Text(newPages == 0 ? "Al passo con il Vault" : "\(newPages) pagine nuove nel Vault")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(newPages == 0 ? DesignColor.success : DesignColor.attention)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(newPages == 0 ? DesignColor.successBg : DesignColor.attentionBg, in: Capsule())
                }
            }
            .padding(DesignSpace.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
                    .stroke(DesignColor.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renamingStudy = study
                renameText = study.name
            } label: {
                Label("Rinomina", systemImage: "pencil")
            }
            if !folders.isEmpty {
                Menu {
                    ForEach(folders) { folder in
                        Button(folder.name) {
                            study.folder = folder
                            study.updatedAt = .now
                        }
                    }
                    if study.folder != nil {
                        Divider()
                        Button("Togli dalla cartella") { study.folder = nil }
                    }
                } label: {
                    Label("Sposta in", systemImage: "folder")
                }
            }
            Divider()
            Button(role: .destructive) {
                if selectedStudy == study { selectedStudy = nil }
                context.delete(study)
            } label: {
                Label("Elimina studio", systemImage: "trash")
            }
        }
    }

    // MARK: - Azioni

    private var renameAlertPresented: Binding<Bool> {
        Binding(get: { renamingStudy != nil }, set: { if !$0 { renamingStudy = nil } })
    }

    private func applyRename() {
        guard let study = renamingStudy else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            study.name = trimmed
            study.updatedAt = .now
        }
        renamingStudy = nil
    }

    private func saveFolder(name: String, color: FolderColor, mode: StudyFolderSheetMode) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        switch mode {
        case .new(let parent):
            context.insert(StudyFolder(name: trimmed, parent: parent, color: color))
        case .edit(let folder):
            folder.name = trimmed
            folder.folderColor = color
        }
    }
}

// MARK: - Sheet cartella di studio
// Stavano in StudioSidebarSection, rimosso quando gli studi sono usciti
// dalla barra laterale.

enum StudyFolderSheetMode: Identifiable {
    case new(parent: StudyFolder?)
    case edit(StudyFolder)

    var id: String {
        switch self {
        case .new(let parent): "new-\(String(describing: parent?.persistentModelID))"
        case .edit(let folder): "edit-\(folder.persistentModelID)"
        }
    }
}

struct StudyFolderEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mode: StudyFolderSheetMode
    var onSave: (String, FolderColor, StudyFolderSheetMode) -> Void

    @State private var name: String
    @State private var color: FolderColor

    init(mode: StudyFolderSheetMode, onSave: @escaping (String, FolderColor, StudyFolderSheetMode) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .new:
            _name = State(initialValue: "")
            _color = State(initialValue: .purple)
        case .edit(let folder):
            _name = State(initialValue: folder.name)
            _color = State(initialValue: folder.folderColor)
        }
    }

    private var isNew: Bool {
        if case .new = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DesignSpace.s5) {
                HStack(spacing: DesignSpace.s3) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(color.color)
                    TextField("Nome del corso (es. Analisi 2)", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .medium))
                }
                .padding(DesignSpace.s3)
                .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))

                VStack(alignment: .leading, spacing: DesignSpace.s2) {
                    Text("COLORE")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(DesignColor.textTertiary)
                    HStack(spacing: DesignSpace.s3) {
                        ForEach(FolderColor.allCases, id: \.self) { option in
                            Button {
                                color = option
                            } label: {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(option.color)
                                    .frame(width: 38, height: 38)
                                    .background(Circle().fill(option.color.opacity(color == option ? 0.15 : 0)))
                                    .overlay(Circle().stroke(option.color, lineWidth: color == option ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Spacer()
            }
            .padding(DesignSpace.s5)
            .navigationTitle(isNew ? "Nuovo Vault" : "Modifica Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Crea" : "Salva") {
                        onSave(name, color, mode)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
