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
    // Il Profilo è un POPOVER con la punta sulla riga Profilo (HANDOFF,
    // passo 4): dentro c'è comunque la testata read di BoostSheet, così
    // su iPhone — dove il sistema lo adatta a foglio — resta la ✕.
    @Binding var showingProfile: Bool

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

    // Eliminazioni in attesa di conferma: una cartella si porta via a
    // cascata sottocartelle e note, e prima bastava una voce di menu
    // senza nessuna domanda.
    @State private var folderPendingDelete: Folder?
    @State private var notePendingDelete: Note?

    var body: some View {
        VStack(spacing: 0) {
            header
            navSection

            // La barra laterale contiene SOLO le cartelle delle note.
            // Gli studi vivono nella pagina di Studio (StudioHomeView):
            // stavano qui in fondo, ma ci si arrivava cliccando in alto,
            // ed erano governati da quattro icone indistinguibili.
            folderListHeader

            // Albero disegnato a mano invece che con List+DisclosureGroup:
            // il design vuole la riga senza freccetta di sistema e le note
            // rientrate dietro una GUIDA VERTICALE, due cose che con la
            // List si possono solo approssimare.
            ScrollView {
                VStack(spacing: 0) {
                    let rootItems = rootFolders.map(SidebarItem.folder) + unfiledNotes.map(SidebarItem.note)
                    ForEach(rootItems) { item in
                        sidebarNode(item)
                    }
                }
                .padding(.horizontal, DesignSpace.s4)
                .padding(.bottom, DesignSpace.s3)
            }
            .id(outlineResetID)

            footer
        }
        // Il fondo IGNORA la safe area: fermandosi sotto la barra di stato
        // lasciava vedere il grigio di sistema sopra e ai lati, e la
        // colonna sembrava una scheda appoggiata sopra la pagina invece di
        // essere il bordo sinistro della pagina stessa.
        .background(DesignColor.surfacePage.ignoresSafeArea())
        // Un filo di bordo sul lato del contenuto: separa senza staccare.
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
        .sheet(item: $renamingNote) { note in
            RenameSheet(title: "Rinomina nota", initialName: note.title) { newName in
                note.title = newName
                note.updatedAt = .now
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
            let count = noteCount(in: folder)
            return Text("Le sue sottocartelle e \(count == 1 ? "la nota che contiene" : "le \(count) note che contiene") verranno eliminate. L'operazione non si può annullare.")
        }
        .alert(
            Text("Eliminare «\(notePendingDelete.map { $0.title.isEmpty ? "Senza titolo" : $0.title } ?? "")»?"),
            isPresented: Binding(
                get: { notePendingDelete != nil },
                set: { if !$0 { notePendingDelete = nil } }
            ),
            presenting: notePendingDelete
        ) { note in
            Button("Annulla", role: .cancel) { notePendingDelete = nil }
            Button("Elimina", role: .destructive) { deleteNote(note) }
        } message: { note in
            Text("Tutte le sue pagine verranno eliminate. L'operazione non si può annullare.")
        }
    }

    // Il marchio: atomo di brand del kit (Wordmark in App.jsx, pesi
    // 200/600), fuori dalla scala tipografica per definizione.
    private static let wordmarkLight = Font.system(size: 22, weight: .ultraLight)
    private static let wordmarkStrong = Font.system(size: 22, weight: .semibold)

    private var header: some View {
        HStack(spacing: 0) {
            Text("Boost")
                .font(Self.wordmarkLight)
            Text("Note")
                .font(Self.wordmarkStrong)
        }
        .foregroundStyle(DesignColor.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignSpace.s6)
        .padding(.top, DesignSpace.s8)
        .padding(.bottom, DesignSpace.s6)
    }

    // Riga fissa sopra all'elenco delle cartelle: etichetta "Cartelle" e,
    // a destra, le azioni rapide (nuova nota, nuova cartella, nuova
    // comprimi tutto). È anche il punto dove trascinare
    // una nota per toglierla dalla cartella in cui si trova.
    private var folderListHeader: some View {
        HStack(spacing: DesignSpace.s2) {
            Text("Cartelle")
                .font(DesignFont.micro)
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(DesignColor.textTertiary)

            if dropTargetingRoot {
                Text("· rilascia per togliere dalla cartella")
                    .font(DesignFont.micro)
                    .foregroundStyle(DesignColor.brandPrimary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            // UN SOLO bottone dove prima ce n'erano tre: le altre due
            // azioni (nuova cartella, comprimi tutto) vivono nel suo menu.
            // Tre icone affiancate erano indistinguibili a colpo d'occhio.
            Menu {
                Button {
                    noteCreateFolder = nil
                    showingNoteCreate = true
                } label: {
                    Label("Nuova nota", systemImage: "note.text.badge.plus")
                }
                Button {
                    folderSheetMode = .new(parent: nil)
                } label: {
                    Label("Nuova cartella", systemImage: "folder.badge.plus")
                }
                Divider()
                Button {
                    expandedFolders.removeAll()
                    outlineResetID = UUID()
                } label: {
                    Label("Comprimi tutto", systemImage: "rectangle.compress.vertical")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: DesignIcon.sm))
                    .foregroundStyle(DesignColor.textSecondary)
                    .frame(width: 22, height: 22)
                    .overlay {
                        Circle().strokeBorder(DesignColor.borderDefault, lineWidth: 1)
                    }
                    .contentShape(Rectangle().inset(by: -11))
            }
            .accessibilityLabel("Nuovo documento")
        }
        .padding(.horizontal, DesignSpace.s6)
        .padding(.bottom, DesignSpace.s3)
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

    // NIENTE TILE: l'attivo si dice con una barra di accento sul bordo
    // sinistro della colonna e col colore, non con un rettangolo pieno.
    // È la stessa grammatica del resto della barra — tipografia, filo,
    // accento — e sotto una nota aperta non lascia macchie di colore.
    private var navSection: some View {
        VStack(spacing: 0) {
            ForEach(AppEnvironment.navItems, id: \.self) { env in
                navRow(icon: env.systemImage, label: env.label, isActive: environment == env) {
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
                }
            }

            navRow(icon: "building.columns", label: "WeBeep", isActive: environment == .webeep, dot: isWebeepConnected ? DesignColor.success : DesignColor.danger) {
                environment = .webeep
                selectedNote = nil
                selectedFolder = nil
            }
        }
        .padding(.bottom, DesignSpace.s6)
    }

    private func navRow(icon: String, label: String, isActive: Bool, dot: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: DesignIcon.md))
                    .foregroundStyle(isActive ? DesignColor.brandPrimary : DesignColor.textSecondary)
                    .frame(width: 18)
                Text(label)
                    .font(isActive ? DesignFont.cardTitle : DesignFont.body)
                    .foregroundStyle(isActive ? DesignColor.brandPrimary : DesignColor.textPrimary)
                Spacer(minLength: 0)
                if let dot {
                    Circle().fill(dot).frame(width: 6, height: 6)
                }
            }
            .padding(.vertical, DesignSpace.s2)
            .padding(.horizontal, DesignSpace.s6)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if isActive {
                    UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 3, topTrailingRadius: 3, style: .continuous)
                        .fill(DesignColor.brandPrimary)
                        .frame(width: 3)
                        .padding(.vertical, DesignSpace.s2)
                }
            }
        }
        .buttonStyle(.plain)
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

    // Stessa grammatica della colonna: nessun tile campito, un cerchio a
    // filo con le iniziali e due righe di testo. Tutta la riga apre il
    // profilo.
    @AppStorage("profileName") private var profileName = ""
    @AppStorage("profileSurname") private var profileSurname = ""

    private var initials: String {
        let letters = [profileName, profileSurname]
            .compactMap { $0.trimmingCharacters(in: .whitespaces).first }
            .map(String.init)
        return letters.joined().uppercased()
    }

    private var footer: some View {
        Button(action: onOpenProfile) {
            HStack(spacing: 12) {
                Group {
                    // Senza nome nel profilo le iniziali non esistono: un
                    // "?" dentro il cerchio sembrerebbe un errore, la
                    // sagoma no.
                    if initials.isEmpty {
                        Image(systemName: "person")
                            .font(.system(size: DesignIcon.md))
                    } else {
                        Text(initials)
                            .font(DesignFont.micro)
                            .tracking(0.3)
                    }
                }
                    .foregroundStyle(DesignColor.brandPrimary)
                    .frame(width: 32, height: 32)
                    .overlay {
                        Circle().strokeBorder(DesignColor.borderDefault, lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text(profileName.isEmpty ? "Profilo" : profileName)
                        .font(DesignFont.cardTitle)
                        .foregroundStyle(DesignColor.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("Profilo e impostazioni")
                        .font(DesignFont.caption)
                        .foregroundStyle(DesignColor.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: DesignIcon.sm))
                    .foregroundStyle(DesignColor.textTertiary)
            }
            .padding(.horizontal, DesignSpace.s5)
            .padding(.vertical, DesignSpace.s4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            Rectangle().fill(DesignColor.borderSubtle).frame(height: 1)
        }
        .popover(isPresented: $showingProfile,
                 attachmentAnchor: .point(UnitPoint(x: 1, y: 0.5)),
                 arrowEdge: .leading) {
            BoostSheet(title: "Profilo", mode: .read, onDismiss: { showingProfile = false }) {
                // Lo stack serve alle pagine di Sviluppo, che si
                // spingono da qui dentro.
                NavigationStack { ProfileView() }
            }
            // 560×720 non stanno su un iPhone: lì il sistema lo adatta
            // a foglio a larghezza piena.
            .frame(width: DeviceLayout.isPhone ? nil : 500,
                   height: DeviceLayout.isPhone ? nil : 640)
            .presentationCompactAdaptation(.sheet)
        }
    }

    // Albero ricorsivo con DisclosureGroup espliciti al posto di
    // OutlineGroup: identico a vedersi, ma l'espansione è NOSTRA — e
    // quindi il doppio tocco può pilotarla. L'AnyView spezza la
    // ricorsione infinita del type-checker.
    @ViewBuilder
    private func sidebarNode(_ item: SidebarItem) -> some View {
        VStack(spacing: 0) {
            row(for: item)
            if case .folder(let folder) = item,
               let children = item.children,
               expandedFolders.contains(folder.persistentModelID) {
                // GUIDA VERTICALE al posto della freccetta: dice dove
                // finisce il contenuto della cartella meglio di un
                // triangolo, e non ruba spazio al nome.
                VStack(spacing: 0) {
                    ForEach(children) { child in
                        AnyView(sidebarNode(child))
                    }
                }
                .padding(.leading, DesignSpace.s1)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(DesignColor.borderDefault)
                        .frame(width: 1.5)
                }
                .padding(.leading, DesignSpace.s4)
                .padding(.bottom, DesignSpace.s1)
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
            let isTarget = dropTargetFolderID == folder.persistentModelID
            HStack(spacing: 10) {
                // L'unico elemento PIENO della colonna: il quadratino del
                // colore del corso. Tutto il resto è linea e tipografia,
                // quindi qui basta poco per identificare la cartella.
                RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                    .fill(folder.folderColor.color)
                    .frame(width: 9, height: 9)
                    .padding(.horizontal, DesignSpace.s1)

                Text(folder.name)
                    .font(DesignFont.body)
                    .foregroundStyle(selectedFolder == folder ? DesignColor.brandPrimary : DesignColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Text("\(folder.notes.count)")
                    .font(DesignFont.caption.monospacedDigit())
                    .foregroundStyle(DesignColor.textTertiary)
            }
            .padding(.vertical, DesignSpace.s2)
            .padding(.horizontal, DesignSpace.s3)
            .background(
                RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                    .fill(isTarget ? DesignColor.brandPrimarySubtle
                          : (selectedFolder == folder ? DesignColor.brandPrimarySubtle.opacity(0.6) : Color.clear))
            )
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
                toggleExpansion(folder)
            }
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
                    folderPendingDelete = folder
                } label: {
                    Label("Elimina cartella", systemImage: "trash")
                }
            }

        case .note(let note):
            let isSelected = selectedNote == note
            HStack(spacing: 8) {
                Image(systemName: note.isWhiteboard ? "scribble.variable" : "note.text")
                    .font(.system(size: DesignIcon.sm))
                    .foregroundStyle(isSelected ? DesignColor.brandPrimary : DesignColor.textTertiary)
                Text(note.title.isEmpty ? "Senza titolo" : note.title)
                    .font(DesignFont.label)
                    .foregroundStyle(isSelected ? DesignColor.brandPrimary : DesignColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.vertical, DesignSpace.s2)
            .padding(.horizontal, DesignSpace.s3)
            .background(
                RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                    .fill(isSelected ? DesignColor.brandPrimarySubtle : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture { selectedNote = note }
            .draggable(note.id.uuidString)
            .contextMenu {
                Button {
                    renamingNote = note
                } label: {
                    Label("Rinomina", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    notePendingDelete = note
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

    // L'eliminazione è a CASCATA su tutto il sottoalbero: le selezioni
    // vanno azzerate per ogni nota e cartella discendente, non solo per
    // le figlie dirette — prima una nota aperta da una SOTTOcartella
    // lasciava l'editor su un @Model eliminato.
    private func deleteFolder(_ folder: Folder) {
        folderPendingDelete = nil
        var noteIDs: Set<PersistentIdentifier> = []
        var folderIDs: Set<PersistentIdentifier> = []
        collectSubtree(of: folder, notes: &noteIDs, folders: &folderIDs)
        if let selectedNote, noteIDs.contains(selectedNote.persistentModelID) {
            self.selectedNote = nil
        }
        if let selectedFolder, folderIDs.contains(selectedFolder.persistentModelID) {
            self.selectedFolder = nil
        }
        context.delete(folder)
    }

    private func collectSubtree(of folder: Folder, notes: inout Set<PersistentIdentifier>, folders: inout Set<PersistentIdentifier>) {
        folders.insert(folder.persistentModelID)
        for note in folder.notes { notes.insert(note.persistentModelID) }
        for child in folder.children { collectSubtree(of: child, notes: &notes, folders: &folders) }
    }

    private func noteCount(in folder: Folder) -> Int {
        folder.notes.count + folder.children.reduce(0) { $0 + noteCount(in: $1) }
    }

    private func deleteNote(_ note: Note) {
        notePendingDelete = nil
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

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        BoostSheet(
            title: isNew ? "Nuova cartella" : "Modifica cartella",
            mode: .commit(verb: isNew ? "Crea" : "Salva", enabled: canSave),
            onDismiss: { dismiss() },
            onConfirm: {
                onSave(name, color, mode)
                dismiss()
            }
        ) {
            VStack(alignment: .leading, spacing: DesignSpace.s5) {
                VStack(alignment: .leading, spacing: DesignSpace.s2) {
                    HStack(spacing: DesignSpace.s3) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: DesignIcon.lg))
                            .foregroundStyle(color.color)
                        TextField("Nome cartella", text: $name)
                            .textFieldStyle(.plain)
                            .font(DesignFont.body)
                    }
                    .padding(DesignSpace.s3)
                    .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                }

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
                                    .background(
                                        Circle().fill(option.color.opacity(color == option ? 0.15 : 0))
                                    )
                                    .overlay(
                                        Circle().stroke(option.color, lineWidth: color == option ? 2 : 0)
                                    )
                                    .contentShape(Rectangle().inset(by: -3))
                            }
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

