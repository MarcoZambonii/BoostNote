import SwiftUI
import SwiftData

// Modale di creazione nota: nome, cartella (con possibilità di crearne
// una nuova al volo) e pattern del foglio.
struct NoteCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Folder.name) private var allFolders: [Folder]

    var onCreated: (Note) -> Void

    @State private var name = ""
    @State private var selectedFolder: Folder?
    @State private var template: NoteTemplate = .blank
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var newFolderColor: FolderColor = .blue

    init(preselectedFolder: Folder? = nil, onCreated: @escaping (Note) -> Void) {
        self.onCreated = onCreated
        _selectedFolder = State(initialValue: preselectedFolder)
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        BoostSheet(
            title: "Nuova nota",
            mode: .commit(verb: "Crea", enabled: canCreate),
            onDismiss: { dismiss() },
            onConfirm: { create() }
        ) {
            Form {
                Section("Nome") {
                    TextField("Nome nota", text: $name)
                }

                Section("Cartella") {
                    Picker("Cartella", selection: $selectedFolder) {
                        Text("Nessuna cartella").tag(Folder?.none)
                        ForEach(allFolders) { folder in
                            Text(folder.name).tag(Optional(folder))
                        }
                    }

                    Toggle("Crea nuova cartella", isOn: $showingNewFolder.animation())

                    if showingNewFolder {
                        TextField("Nome nuova cartella", text: $newFolderName)
                        HStack(spacing: DesignSpace.s2) {
                            ForEach(FolderColor.allCases, id: \.self) { option in
                                Button {
                                    newFolderColor = option
                                } label: {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: DesignIcon.md))
                                        .foregroundStyle(option.color)
                                        .frame(width: 28, height: 28)
                                        .overlay(
                                            Circle().stroke(option.color, lineWidth: newFolderColor == option ? 2 : 0)
                                        )
                                }
                            }
                        }
                    }
                }

                Section("Pattern foglio") {
                    BoostSegmented(
                        options: NoteTemplate.allCases.map { ($0, $0.label) },
                        selection: $template
                    )
                }
            }
            // Il fondo grigio di sistema sotto il Form non è di
            // quest'app: sotto ci va il foglio bianco come nel resto
            // delle schermate.
            .scrollContentBackground(.hidden)
            .background(DesignColor.surfacePage)
        }
        .presentationDetents([.medium])
    }

    private func create() {
        var folder = selectedFolder
        if showingNewFolder {
            let trimmed = newFolderName.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                let newFolder = Folder(name: trimmed, parent: nil, color: newFolderColor)
                context.insert(newFolder)
                folder = newFolder
            }
        }
        let note = Note(title: name.trimmingCharacters(in: .whitespaces), folder: folder)
        note.template = template
        context.insert(note)
        onCreated(note)
        dismiss()
    }
}
