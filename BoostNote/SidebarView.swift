import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// Elemento della barra laterale: una cartella o una nota, usato per
// costruire l'albero a cascata con OutlineGroup (cartelle e note
// annidate sotto lo stesso nodo).
private enum SidebarItem: Identifiable, Hashable {
    case folder(Folder)
    case note(Note)

    var id: PersistentIdentifier {
        switch self {
        case .folder(let folder): folder.persistentModelID
        case .note(let note): note.persistentModelID
        }
    }

    static func == (lhs: SidebarItem, rhs: SidebarItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var children: [SidebarItem]? {
        guard case .folder(let folder) = self else { return nil }
        let subfolders = folder.children.sorted { $0.name < $1.name }.map(SidebarItem.folder)
        let notes = folder.notes.sorted { $0.updatedAt > $1.updatedAt }.map(SidebarItem.note)
        let combined = subfolders + notes
        return combined.isEmpty ? nil : combined
    }
}

// Creazione o modifica di una cartella (nome + colore), presentata come sheet.
enum FolderSheetMode: Identifiable {
    case new(parent: Folder?)
    case edit(Folder)

    var id: String {
        switch self {
        case .new(let parent): "new-\(parent?.persistentModelID)"
        case .edit(let folder): "edit-\(folder.persistentModelID)"
        }
    }
}

struct SidebarView: View {
    @Environment(\.modelContext) private var context
    @Binding var environment: AppEnvironment
    @Binding var selectedNote: Note?
    @Binding var selectedFolder: Folder?
    @Binding var selectedStudy: Study?
    @Binding var selectedStudyModule: StudyModule?
    @Binding var showingStudioProgress: Bool
    var onCreateStudy: () -> Void
    var onOpenProfile: () -> Void

    @Query(filter: #Predicate<Folder> { $0.parent == nil }, sort: \Folder.name)
    private var rootFolders: [Folder]

    // Note create importando un PDF senza scegliere una cartella:
    // restano visibili in cima alla barra laterale.
    @Query(filter: #Predicate<Note> { $0.folder == nil }, sort: \Note.updatedAt, order: .reverse)
    private var unfiledNotes: [Note]

    // Usata per risolvere il drag-and-drop tra cartelle (il payload
    // trascinato è solo l'UUID della nota, non il riferimento diretto).
    @Query private var allNotes: [Note]

    @State private var dropTargetFolderID: PersistentIdentifier?
    @State private var dropTargetingRoot = false
    @State private var outlineResetID = UUID()
    // Cartelle aperte nell'albero. Rimpiazza l'espansione interna di
    // OutlineGroup, che non è pilotabile: serve un Set nostro perché il
    // DOPPIO TOCCO su una cartella deve aprire/chiudere la tendina.
    @State private var expandedFolders: Set<PersistentIdentifier> = []

    @State private var folderSheetMode: FolderSheetMode?

    @State private var showingNoteCreate = false
    @State private var noteCreateFolder: Folder?

    @State private var renamingNote: Note?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            navSection

            // La barra laterale contiene SOLO le cartelle delle note.
            // Gli studi vivono nella pagina di Studio (StudioHomeView):
            // stavano qui in fondo, ma ci si arrivava cliccando in alto,
            // ed erano governati da quattro icone indistinguibili.
            folderListHeader

            List(selection: $selectedNote) {
                let rootItems = rootFolders.map(SidebarItem.folder) + unfiledNotes.map(SidebarItem.note)
                ForEach(rootItems) { item in
                    sidebarNode(item)
                }
            }
            .id(outlineResetID)
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 34)

            footer
        }
        .background(DesignColor.surfaceSunken)
        // Un filo di bordo sul lato del contenuto: stacca la barra dal
        // foglio bianco della pagina (mock utente 2026-08-16 — prima i
        // due grigi si fondevano e la barra "galleggiava" senza confine).
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(DesignColor.borderSubtle)
                .frame(width: 1)
                .ignoresSafeArea()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $folderSheetMode) { mode in
            FolderEditSheet(mode: mode, onSave: saveFolder)
        }
        .sheet(isPresented: $showingNoteCreate) {
            NoteCreateSheet(preselectedFolder: noteCreateFolder) { note in
                selectedNote = note
            }
        }
        .alert("Rinomina nota", isPresented: renameAlertPresented) {
            TextField("Nome", text: $renameText)
            Button("Annulla", role: .cancel) { renamingNote = nil }
            Button("Salva") {
                applyNoteRename()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Boost")
                .fontWeight(.ultraLight)
            Text("Note")
                .fontWeight(.semibold)
        }
        .font(.system(size: 21))
        .foregroundStyle(DesignColor.textPrimary)
        .padding(.horizontal, DesignSpace.s5)
        .padding(.top, DesignSpace.s5 + 2)
        .padding(.bottom, DesignSpace.s3 + 2)
    }

    // Riga fissa sopra all'elenco delle cartelle: etichetta "Cartelle" e,
    // a destra, le azioni rapide (nuova nota, nuova cartella, nuova
    // comprimi tutto). È anche il punto dove trascinare
    // una nota per toglierla dalla cartella in cui si trova.
    private var folderListHeader: some View {
        HStack(spacing: DesignSpace.s3) {
            Text("Cartelle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)

            if dropTargetingRoot {
                Text("· rilascia per togliere dalla cartella")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignColor.brandPrimary)
            }

            Spacer()

            Button {
                noteCreateFolder = nil
                showingNoteCreate = true
            } label: {
                Image(systemName: "note.text.badge.plus")
            }
            .accessibilityLabel("Nuova nota")

            Button {
                folderSheetMode = .new(parent: nil)
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .accessibilityLabel("Nuova cartella")

            Button {
                expandedFolders.removeAll()
                outlineResetID = UUID()
            } label: {
                Image(systemName: "rectangle.compress.vertical")
            }
            .accessibilityLabel("Comprimi tutte le cartelle")
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(DesignColor.textSecondary)
        .padding(.horizontal, DesignSpace.s3 + 2)
        .padding(.vertical, DesignSpace.s2)
        .background(
            dropTargetingRoot ? DesignColor.brandPrimarySubtle : Color.clear,
            in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
        )
        .dropDestination(for: String.self) { items, _ in
            handleNoteDropStrings(items, into: nil)
            return true
        } isTargeted: { targeted in
            dropTargetingRoot = targeted
        }
    }

    private var navSection: some View {
        VStack(spacing: 2) {
            ForEach(AppEnvironment.navItems, id: \.self) { env in
                Button {
                    environment = env
                    if env == .home {
                        selectedNote = nil
                        selectedFolder = nil
                    }
                    // Toccare "Studio" torna sempre alla sua pagina
                    // iniziale: senza questo, chi era dentro a uno studio
                    // ci restava e il pulsante sembrava non fare nulla.
                    if env == .studio {
                        selectedStudy = nil
                        selectedStudyModule = nil
                        showingStudioProgress = false
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: env.systemImage)
                            .font(.system(size: 15))
                            .frame(width: 20)
                        Text(env.label)
                            .font(.system(size: 14, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(environment == env ? DesignColor.brandPrimary : DesignColor.textPrimary)
                    .padding(.vertical, DesignSpace.s2)
                    .padding(.horizontal, DesignSpace.s2 + 2)
                    .background(
                        environment == env ? DesignColor.brandPrimarySubtle : Color.clear,
                        in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }

            Button {
                environment = .webeep
                selectedNote = nil
                selectedFolder = nil
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "building.columns.fill")
                        .font(.system(size: 15))
                        .frame(width: 20)
                    Text("WeBeep")
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    Circle()
                        .fill(isWebeepConnected ? DesignColor.success : DesignColor.danger)
                        .frame(width: 8, height: 8)
                }
                .foregroundStyle(environment == .webeep ? DesignColor.brandPrimary : DesignColor.textPrimary)
                .padding(.vertical, DesignSpace.s2)
                .padding(.horizontal, DesignSpace.s2 + 2)
                .background(
                    environment == .webeep ? DesignColor.brandPrimarySubtle : Color.clear,
                    in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DesignSpace.s3 - 2)
        .padding(.bottom, DesignSpace.s3)
    }

    // Menu "Nuovo documento": scegli tra cartella o nota.
    // Usato sia dalla barra laterale che dalla toolbar in alto.
    @ViewBuilder
    private func newDocumentMenu(folder: Folder?, @ViewBuilder label: () -> some View) -> some View {
        Menu {
            Button {
                folderSheetMode = .new(parent: folder)
            } label: {
                Label("Cartella", systemImage: "folder.badge.plus")
            }
            Button {
                noteCreateFolder = folder
                showingNoteCreate = true
            } label: {
                Label("Nota", systemImage: "note.text.badge.plus")
            }
        } label: {
            label()
        }
    }

    // WeBeep connesso se esiste un token salvato in Keychain (verificato
    // davvero all'apertura del Profilo, che disconnette se non è più valido).
    private var isWebeepConnected: Bool {
        WebeepService.savedToken != nil
    }

    private var footer: some View {
        HStack(spacing: DesignSpace.s3) {
            Button(action: onOpenProfile) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(DesignColor.textSecondary)
                    Text("Profilo")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DesignColor.textPrimary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DesignSpace.s4)
        .padding(.vertical, DesignSpace.s3)
        .overlay(alignment: .top) {
            Rectangle().fill(DesignColor.borderDefault).frame(height: 1)
        }
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renamingNote != nil },
            set: { if !$0 { renamingNote = nil } }
        )
    }

    // Albero ricorsivo con DisclosureGroup espliciti al posto di
    // OutlineGroup: identico a vedersi, ma l'espansione è NOSTRA — e
    // quindi il doppio tocco può pilotarla. L'AnyView spezza la
    // ricorsione infinita del type-checker.
    @ViewBuilder
    private func sidebarNode(_ item: SidebarItem) -> some View {
        switch item {
        case .note:
            row(for: item)
        case .folder(let folder):
            if let children = item.children {
                DisclosureGroup(isExpanded: expansionBinding(folder)) {
                    ForEach(children) { child in
                        AnyView(sidebarNode(child))
                    }
                } label: {
                    row(for: item)
                }
            } else {
                row(for: item)
            }
        }
    }

    private func expansionBinding(_ folder: Folder) -> Binding<Bool> {
        Binding(
            get: { expandedFolders.contains(folder.persistentModelID) },
            set: { open in
                if open {
                    expandedFolders.insert(folder.persistentModelID)
                } else {
                    expandedFolders.remove(folder.persistentModelID)
                }
            }
        )
    }

    private func toggleExpansion(_ folder: Folder) {
        withAnimation(.snappy(duration: 0.22)) {
            if expandedFolders.contains(folder.persistentModelID) {
                expandedFolders.remove(folder.persistentModelID)
            } else {
                expandedFolders.insert(folder.persistentModelID)
            }
        }
    }

    @ViewBuilder
    private func row(for item: SidebarItem) -> some View {
        switch item {
        case .folder(let folder):
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    // Tessera MORBIDA (mock utente 2026-08-16, secondo
                    // giro): tinta al 15% con il glifo nel colore — la
                    // versione piena era troppo accesa accanto al resto
                    // del documento. Niente conteggio elementi: non è
                    // un'informazione utile (sua richiesta esplicita).
                    RoundedRectangle(cornerRadius: DesignRadius.sm + 1, style: .continuous)
                        .fill(folder.folderColor.color.opacity(0.15))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Image(systemName: "folder.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(folder.folderColor.color)
                        )
                    Text(folder.name)
                        .font(.system(size: 14, weight: selectedFolder == folder ? .semibold : .medium))
                        .foregroundStyle(selectedFolder == folder ? DesignColor.brandPrimary : DesignColor.textPrimary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                // L'ordine conta: il doppio tocco va dichiarato PRIMA del
                // singolo, così SwiftUI aspetta a decidere. Due tocchi =
                // apri/chiudi la tendina; uno = apri la cartella.
                .onTapGesture(count: 2) {
                    toggleExpansion(folder)
                }
                .onTapGesture {
                    selectedNote = nil
                    selectedFolder = folder
                }

                newDocumentMenu(folder: folder) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(DesignColor.textTertiary)
                }
                .accessibilityLabel("Nuovo documento in \(folder.name)")
            }
            .padding(.vertical, DesignSpace.s2 + 1)
            .padding(.horizontal, DesignSpace.s2 + 2)
            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
            .listRowSeparator(.hidden)
            .background(
                RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                    .fill(
                        dropTargetFolderID == folder.persistentModelID
                            ? DesignColor.brandPrimarySubtle
                            : (selectedFolder == folder ? DesignColor.brandPrimarySubtle.opacity(0.6) : Color.clear)
                    )
            )
            .listRowBackground(Color.clear)
            .dropDestination(for: String.self) { items, _ in
                handleNoteDropStrings(items, into: folder)
                return true
            } isTargeted: { targeted in
                dropTargetFolderID = targeted ? folder.persistentModelID : nil
            }
            .contextMenu {
                Button {
                    noteCreateFolder = folder
                    showingNoteCreate = true
                } label: {
                    Label("Nuova nota qui", systemImage: "note.text.badge.plus")
                }
                Button {
                    folderSheetMode = .new(parent: folder)
                } label: {
                    Label("Nuova sottocartella qui", systemImage: "folder.badge.plus")
                }
                Button {
                    folderSheetMode = .edit(folder)
                } label: {
                    Label("Rinomina / colore", systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive) {
                    deleteFolder(folder)
                } label: {
                    Label("Elimina cartella", systemImage: "trash")
                }
            }

        case .note(let note):
            let isSelected = selectedNote == note
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                    .fill(DesignColor.surfacePage)
                    .frame(width: 26, height: 26)
                    .overlay(
                        Image(systemName: "note.text")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isSelected ? DesignColor.brandPrimary : DesignColor.textSecondary)
                    )
                Text(note.title.isEmpty ? "Senza titolo" : note.title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(isSelected ? DesignColor.brandPrimary : DesignColor.textPrimary)
            .padding(.vertical, DesignSpace.s2 + 1)
            .padding(.horizontal, DesignSpace.s2 + 2)
            .background(
                RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                    .fill(isSelected ? DesignColor.brandPrimarySubtle : Color.clear)
            )
            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .tag(note)
            .draggable(note.id.uuidString)
            .contextMenu {
                Button {
                    renamingNote = note
                    renameText = note.title
                } label: {
                    Label("Rinomina", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    deleteNote(note)
                } label: {
                    Label("Elimina nota", systemImage: "trash")
                }
            }
        }
    }

    // Sposta le note trascinate (identificate per UUID) nella cartella di
    // destinazione, o le sfila se folder è nil.
    private func handleNoteDropStrings(_ items: [String], into folder: Folder?) {
        for idString in items {
            guard let uuid = UUID(uuidString: idString),
                  let note = allNotes.first(where: { $0.id == uuid }) else { continue }
            note.folder = folder
            note.updatedAt = .now
        }
    }

    private func saveFolder(name: String, color: FolderColor, mode: FolderSheetMode) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        switch mode {
        case .new(let parent):
            let folder = Folder(name: trimmed, parent: parent, color: color)
            context.insert(folder)
        case .edit(let folder):
            folder.name = trimmed
            folder.folderColor = color
        }
    }

    private func applyNoteRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let note = renamingNote else {
            renamingNote = nil
            return
        }
        note.title = trimmed
        note.updatedAt = .now
        renamingNote = nil
    }

    private func deleteFolder(_ folder: Folder) {
        if let selectedNote, folder.notes.contains(selectedNote) {
            self.selectedNote = nil
        }
        context.delete(folder)
    }

    private func deleteNote(_ note: Note) {
        if selectedNote == note { selectedNote = nil }
        context.delete(note)
    }

}

// Nome + colore di una cartella, per creazione o modifica.
struct FolderEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mode: FolderSheetMode
    var onSave: (String, FolderColor, FolderSheetMode) -> Void

    @State private var name: String
    @State private var color: FolderColor

    init(mode: FolderSheetMode, onSave: @escaping (String, FolderColor, FolderSheetMode) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .new:
            _name = State(initialValue: "")
            _color = State(initialValue: .blue)
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
                VStack(alignment: .leading, spacing: DesignSpace.s2) {
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
                }

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
                                    .background(
                                        Circle().fill(option.color.opacity(color == option ? 0.15 : 0))
                                    )
                                    .overlay(
                                        Circle().stroke(option.color, lineWidth: color == option ? 2 : 0)
                                    )
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(DesignSpace.s5)
            .navigationTitle(isNew ? "Nuova cartella" : "Modifica cartella")
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

