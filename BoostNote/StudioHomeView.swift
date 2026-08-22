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

    // Eliminazioni in attesa di conferma: un Vault si porta via ore di
    // letture pagate in chiamate API, uno studio i suoi moduli generati —
    // prima bastava una voce di menu senza nessuna domanda.
    @State private var folderPendingDelete: StudyFolder?
    @State private var studyPendingDelete: Study?

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
        .sheet(item: $renamingStudy) { study in
            RenameSheet(title: "Rinomina studio", initialName: study.name) { newName in
                study.name = newName
                study.updatedAt = .now
            }
        }
        .alert(
            Text("Eliminare «\(folderPendingDelete?.name ?? "")»?"),
            isPresented: Binding(
                get: { folderPendingDelete != nil },
                set: { if !$0 { folderPendingDelete = nil } }
            ),
            presenting: folderPendingDelete
        ) { folder in
            Button("Annulla", role: .cancel) { folderPendingDelete = nil }
            Button("Elimina", role: .destructive) { deleteFolder(folder) }
        } message: { folder in
            let documents = folder.vaultDocuments.count
            return Text("\(documents == 1 ? "Il documento del Vault e le sue pagine lette verranno eliminati" : "I \(documents) documenti del Vault e le loro pagine lette verranno eliminati"). Gli studi dentro non vengono eliminati: tornano alla radice.")
        }
        .alert(
            Text("Eliminare «\(studyPendingDelete?.name ?? "")»?"),
            isPresented: Binding(
                get: { studyPendingDelete != nil },
                set: { if !$0 { studyPendingDelete = nil } }
            ),
            presenting: studyPendingDelete
        ) { study in
            Button("Annulla", role: .cancel) { studyPendingDelete = nil }
            Button("Elimina", role: .destructive) { deleteStudy(study) }
        } message: { study in
            Text("I suoi moduli generati e i tentativi registrati nell'analisi dei progressi verranno eliminati.")
        }
    }

    // Titolo a sinistra, azioni di CORNICE a destra: creare un Vault e
    // guardare i progressi non sono l'azione principale della pagina —
    // lo sono i Vault che già esistono, con i loro studi. Prima una card
    // blu a tutta larghezza gridava "Crea nuovo studio" sopra ogni cosa,
    // e portava a un flusso che poteva anche non passare dal Vault.
    @ViewBuilder
    private var header: some View {
        // `ViewThatFits` misura lo spazio disponibile invece di dedurlo
        // dal dispositivo: `horizontalSizeClass`, che c'era prima, è lo
        // stesso segnale sbagliato già corretto sulla testata della Home
        // — un iPad in verticale con la barra laterale aperta resta
        // `.regular` con una larghezza da iPhone. La variante affiancata
        // porta il sottotitolo NON comprimibile, così quando non entra si
        // passa davvero alla variante impilata.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DesignSpace.s4) {
                headerTitle(compactSubtitle: true)
                Spacer(minLength: DesignSpace.s4)
                headerButtons
            }
            VStack(alignment: .leading, spacing: DesignSpace.s4) {
                headerTitle(compactSubtitle: false)
                // I due pulsanti insieme possono superare la larghezza di
                // un iPhone: la riga scorre invece di schiacciarli.
                ScrollView(.horizontal, showsIndicators: false) {
                    headerButtons
                }
                .scrollClipDisabled()
            }
        }
    }

    private func headerTitle(compactSubtitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Studio")
                    .font(DesignFont.screenTitle)
                    .foregroundStyle(DesignColor.textPrimary)
                Image(systemName: "graduationcap.fill")
                    .foregroundStyle(DesignColor.brandPrimary)
            }
            Text(subtitleText)
                .font(DesignFont.body)
                .foregroundStyle(DesignColor.textTertiary)
                .lineLimit(compactSubtitle ? 1 : nil)
                .fixedSize(horizontal: compactSubtitle, vertical: false)
        }
    }

    private var headerButtons: some View {
        HStack(spacing: DesignSpace.s2) {
            headerButton(title: "Analisi progressi", icon: "chart.bar.xaxis", tint: DesignColor.insight) {
                showingProgress = true
            }
            headerButton(title: "Nuovo Vault", icon: "plus", tint: DesignColor.brandPrimary) {
                folderSheet = .new(parent: nil)
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
                .font(DesignFont.action)
                .lineLimit(1)
                .fixedSize()
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
        BoostState(
            kind: .empty,
            title: "Nessun Vault, per ora",
            message: "Un Vault per corso: ci metti dentro note, dispense, temi d'esame e file WeBeep. Vengono letti una volta e restano pronti per generare riassunti, esercizi e flashcard senza rileggere niente.",
            action: AnyView(BoostButton("Crea il primo Vault", icon: "plus", tone: .primary) {
                folderSheet = .new(parent: nil)
            })
        )
        .padding(.vertical, DesignSpace.s8)
    }

    private func studySection(title: String, icon: String, tint: Color, studies: [Study], folder: StudyFolder?) -> some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            HStack(spacing: DesignSpace.s2) {
                Image(systemName: icon)
                    .font(.system(size: DesignIcon.md))
                    .foregroundStyle(tint)
                Text(title.uppercased())
                    .font(DesignFont.micro)
                    .tracking(0.6)
                    .foregroundStyle(DesignColor.textSecondary)
                Text("\(studies.count)")
                    .font(DesignFont.caption)
                    .foregroundStyle(DesignColor.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
                Spacer()
                if let folder {
                    // Accesso rapido al vault: se ha già materiale si vede
                    // anche fuori dal menu.
                    if !folder.vaultDocuments.isEmpty {
                        Button {
                            vaultFolder = folder
                        } label: {
                            Label("\(folder.vaultDocuments.count) nel Vault", systemImage: "archivebox.fill")
                                .font(DesignFont.caption)
                                .foregroundStyle(DesignColor.brandPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(DesignColor.brandPrimarySubtle, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
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
                            folderPendingDelete = folder
                        } label: {
                            Label("Elimina Vault e cartella", systemImage: "trash")
                        }
                        Text("Gli studi dentro non vengono eliminati.")
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: DesignIcon.md))
                            .foregroundStyle(DesignColor.textTertiary)
                    }
                }
            }

            if studies.isEmpty {
                BoostState(
                    kind: .empty,
                    title: "Nessuno studio in questa cartella",
                    message: "Dal menu ⋯ apri il Vault del corso: il materiale viene letto una volta e resta pronto per studi, esercizi e ripassi."
                )
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
                            .font(.system(size: DesignIcon.md))
                            .foregroundStyle(folder.folderColor.color)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(DesignFont.cardTitle)
                        .foregroundStyle(DesignColor.textPrimary)
                    Text(vaultSubtitle(for: documents))
                        .font(DesignFont.caption)
                        .foregroundStyle(DesignColor.textTertiary)
                }
                Spacer()
                if isIngesting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Leggo…")
                            .font(DesignFont.caption)
                            .foregroundStyle(DesignColor.textTertiary)
                    }
                } else if !documents.isEmpty {
                    // Una porta sola per il materiale: "Gestisci" apre il
                    // Vault, dove si vede l'elenco e si aggiorna. Prima
                    // c'erano una ⓘ per sbirciare e un "Aggiorna" a
                    // parte: due mezze porte invece di una intera.
                    // Testata di card: l'unico posto dove è ammesso il 38.
                    BoostButton("Gestisci Vault", icon: "archivebox", size: .compact) {
                        vaultFolder = folder
                    }
                }
                Menu {
                    Button {
                        folderSheet = .edit(folder)
                    } label: {
                        Label("Rinomina / colore", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        folderPendingDelete = folder
                    } label: {
                        Label("Elimina Vault e cartella", systemImage: "trash")
                    }
                    Text("Gli studi dentro non vengono eliminati.")
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: DesignIcon.md))
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
                        .font(DesignFont.action)
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
                        .font(DesignFont.micro)
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
                                .font(DesignFont.action)
                                .foregroundStyle(DesignColor.textOnBrand)
                                .padding(.horizontal, DesignSpace.s4)
                                .padding(.vertical, DesignSpace.s2)
                                .background(DesignColor.brandPrimary, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
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
                .font(DesignFont.caption)
                .foregroundStyle(DesignColor.textTertiary)
        } else if pending > 0 {
            Label("\(pending) pagine da leggere", systemImage: "clock")
                .font(DesignFont.caption)
                .foregroundStyle(DesignColor.attention)
        } else if failed > 0 {
            Label("\(read) lette · \(failed) non riuscite", systemImage: "exclamationmark.triangle")
                .font(DesignFont.caption)
                .foregroundStyle(DesignColor.attention)
        } else {
            Label("\(read) pagine lette", systemImage: "checkmark")
                .font(DesignFont.caption)
                .foregroundStyle(DesignColor.success)
        }
    }

    private func emptyStudiesArea(_ folder: StudyFolder, documents: [VaultDocument]) -> some View {
        let readPages = documents.reduce(0) { $0 + $1.readCount }
        return BoostState(
            kind: .empty,
            title: "Nessuno studio ancora",
            message: readPages > 0
                ? "Il Vault è pronto: \(readPages) pagine già lette. Genera il primo studio quando vuoi — il materiale non verrà riletto."
                : "Aggiungi il materiale del corso al Vault, oppure crea uno studio partendo dalle note.",
            action: readPages > 0
                ? AnyView(BoostButton("Crea da questo Vault", icon: "plus", size: .compact) {
                    onCreateStudy(folder)
                })
                : nil
        )
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
                                .font(.system(size: DesignIcon.md))
                                .foregroundStyle(DesignColor.brandPrimary)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(study.name)
                            .font(DesignFont.cardTitle)
                            .foregroundStyle(DesignColor.textPrimary)
                            .lineLimit(1)
                        Text(study.updatedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(DesignFont.caption)
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
                                        .font(.system(size: DesignIcon.sm))
                                    if module.status == .failed {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: DesignIcon.sm))
                                    } else if module.status == .generating {
                                        ProgressView().controlSize(.mini)
                                    }
                                }
                                .foregroundStyle(module.status == .failed ? DesignColor.danger : kind.color)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(
                                    (module.status == .failed ? DesignColor.danger : kind.color).opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
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
                            .font(.system(size: DesignIcon.sm))
                        Text(newPages == 0 ? "Al passo con il Vault" : "\(newPages) pagine nuove nel Vault")
                    }
                    .font(DesignFont.caption)
                    .foregroundStyle(newPages == 0 ? DesignColor.success : DesignColor.attention)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(newPages == 0 ? DesignColor.successBg : DesignColor.attentionBg, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
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
                studyPendingDelete = study
            } label: {
                Label("Elimina studio", systemImage: "trash")
            }
        }
    }

    // MARK: - Azioni


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

    private func deleteFolder(_ folder: StudyFolder) {
        folderPendingDelete = nil
        // Il Vault della cartella sta venendo letto? Il servizio ha le
        // sue guardie sui modelli eliminati, ma se la sheet del Vault è
        // aperta su questa cartella va chiusa: resterebbe su un morto.
        if vaultFolder?.persistentModelID == folder.persistentModelID {
            vaultFolder = nil
        }
        context.delete(folder)
    }

    private func deleteStudy(_ study: Study) {
        studyPendingDelete = nil
        // Una generazione in corso su questo studio va fermata: il suo
        // task, al completamento, scriverebbe su moduli eliminati.
        StudioGenerationService.cancelGeneration(for: study.id)
        if selectedStudy == study { selectedStudy = nil }
        context.delete(study)
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

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        BoostSheet(
            title: isNew ? "Nuovo Vault" : "Modifica Vault",
            mode: .commit(verb: isNew ? "Crea" : "Salva", enabled: canSave),
            onDismiss: { dismiss() },
            onConfirm: {
                onSave(name, color, mode)
                dismiss()
            }
        ) {
            VStack(alignment: .leading, spacing: DesignSpace.s5) {
                HStack(spacing: DesignSpace.s3) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: DesignIcon.lg))
                        .foregroundStyle(color.color)
                    TextField("Nome del corso (es. Analisi 2)", text: $name)
                        .textFieldStyle(.plain)
                        .font(DesignFont.body)
                }
                .padding(DesignSpace.s3)
                .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))

                VStack(alignment: .leading, spacing: DesignSpace.s2) {
                    Text("COLORE")
                        .font(DesignFont.micro)
                        .tracking(0.6)
                        .foregroundStyle(DesignColor.textTertiary)
                    HStack(spacing: DesignSpace.s3) {
                        ForEach(FolderColor.allCases, id: \.self) { option in
                            Button {
                                color = option
                            } label: {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: DesignIcon.lg))
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
        }
        .presentationDetents([.height(420)])
    }
}
