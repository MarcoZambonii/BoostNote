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
    var onCreateStudy: () -> Void

    @Query(sort: \StudyFolder.name) private var folders: [StudyFolder]
    @Query(sort: \Study.updatedAt, order: .reverse) private var studies: [Study]

    @State private var folderSheet: StudyFolderSheetMode?
    @State private var renamingStudy: Study?
    @State private var renameText = ""

    private var looseStudies: [Study] { studies.filter { $0.folder == nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpace.s8) {
                header
                actions

                if studies.isEmpty {
                    emptyState
                } else {
                    ForEach(folders) { folder in
                        studySection(
                            title: folder.name,
                            icon: "folder.fill",
                            tint: folder.folderColor.color,
                            studies: folder.sortedStudies,
                            folder: folder
                        )
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
        .alert("Rinomina studio", isPresented: renameAlertPresented) {
            TextField("Nome", text: $renameText)
            Button("Annulla", role: .cancel) { renamingStudy = nil }
            Button("Salva") { applyRename() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Studio")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(DesignColor.textPrimary)
                Image(systemName: "graduationcap.fill")
                    .foregroundStyle(DesignColor.brandPrimary)
            }
            Text(studies.isEmpty
                 ? "Genera ripassi, esercizi e flashcard dai tuoi materiali."
                 : "\(studies.count) stud\(studies.count == 1 ? "io" : "i") · \(totalExercises) esercizi generati")
                .font(.system(size: 14))
                .foregroundStyle(DesignColor.textTertiary)
        }
    }

    private var totalExercises: Int {
        studies.reduce(0) { partial, study in
            partial + study.sortedModules
                .filter { $0.kind == .exercises && $0.status == .ready }
                .reduce(0) { $0 + ($1.decodeContent(ExerciseSetContent.self)?.exercises.count ?? 0) }
        }
    }

    // Gerarchia esplicita: l'azione principale prende tutta la larghezza,
    // le due secondarie stanno affiancate sotto. Tre card uguali in fila
    // non dicono quale sia la cosa da fare.
    private var actions: some View {
        VStack(spacing: DesignSpace.s3) {
            actionCard(
                title: "Crea nuovo studio",
                subtitle: "Da note, dispense o temi d'esame",
                icon: "plus",
                tint: DesignColor.brandPrimary,
                prominent: true,
                action: onCreateStudy
            )
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSpace.s3) { secondaryActions }
                VStack(spacing: DesignSpace.s3) { secondaryActions }
            }
        }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        actionCard(
            title: "Analisi dei progressi",
            subtitle: "Come stai andando",
            icon: "chart.bar.xaxis",
            tint: DesignColor.toolExplain,
            prominent: false
        ) {
            showingProgress = true
        }
        actionCard(
            title: "Nuova cartella",
            subtitle: "Organizza per materia",
            icon: "folder.badge.plus",
            tint: DesignColor.toolLatex,
            prominent: false
        ) {
            folderSheet = .new(parent: nil)
        }
    }

    private func actionCard(title: String, subtitle: String, icon: String, tint: Color, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DesignSpace.s3) {
                RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                    .fill(prominent ? Color.white.opacity(0.2) : tint.opacity(0.12))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(prominent ? Color.white : tint)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(prominent ? Color.white : DesignColor.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(prominent ? Color.white.opacity(0.85) : DesignColor.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(DesignSpace.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                prominent ? DesignColor.brandPrimary : DesignColor.surfaceSunken,
                in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: DesignSpace.s3) {
            Image(systemName: "books.vertical")
                .font(.system(size: 36))
                .foregroundStyle(DesignColor.textTertiary)
            Text("Nessuno studio, per ora")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)
            Text("Scegli note, dispense o temi d'esame e lascia che l'app ne ricavi riassunti, esercizi e flashcard.")
                .font(.system(size: 13))
                .foregroundStyle(DesignColor.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
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
                    Menu {
                        Button {
                            folderSheet = .edit(folder)
                        } label: {
                            Label("Rinomina / colore", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            context.delete(folder)
                        } label: {
                            Label("Elimina cartella", systemImage: "trash")
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
                Text("Cartella vuota — sposta qui uno studio dal suo menu, oppure eliminala.")
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

    private func studyCard(_ study: Study) -> some View {
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
            }
            .padding(DesignSpace.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
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
                    TextField("Nome cartella", text: $name)
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
            .navigationTitle(isNew ? "Nuova cartella di studio" : "Modifica cartella")
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
