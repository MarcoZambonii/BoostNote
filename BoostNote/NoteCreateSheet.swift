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

    var body: some View {
        NavigationStack {
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
                                        .font(.system(size: 16))
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
                    Picker("Pattern", selection: $template) {
                        ForEach(NoteTemplate.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Nuova nota")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crea") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
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
