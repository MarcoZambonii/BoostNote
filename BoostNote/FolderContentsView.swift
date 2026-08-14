import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// Come mostrare sottocartelle e note: griglia di card o lista compatta.
enum FolderViewMode: String {
    case grid, list

    var systemImage: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }
}

// Contenuto di una cartella mostrato a destra quando la si apre dalla
// barra laterale: sottocartelle e note al suo interno, in stile Home.
struct FolderContentsView: View {
    @Environment(\.modelContext) private var context
    @Bindable var folder: Folder
    @Binding var selectedNote: Note?
    @Binding var selectedFolder: Folder?

    @AppStorage("folderContentsViewMode") private var viewModeRaw = FolderViewMode.grid.rawValue
    private var viewMode: FolderViewMode { FolderViewMode(rawValue: viewModeRaw) ?? .grid }

    @State private var showingNoteCreate = false
    @State private var showingNewFolderSheet = false
    @State private var showingPDFImporter = false

    private var subfolders: [Folder] { folder.children.sorted { $0.name < $1.name } }
    private var notes: [Note] { folder.notes.sorted { $0.updatedAt > $1.updatedAt } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpace.s8) {
                HStack(spacing: DesignSpace.s3) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(folder.folderColor.color)
                    Text(folder.name)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(DesignColor.textPrimary)
                    Spacer()
                    viewModePicker
                }

                HStack(spacing: DesignSpace.s4) {
                    quickActionCard(title: "Nuova nota", subtitle: "In \(folder.name)", icon: "square.and.pencil", color: DesignColor.brandPrimary) {
                        showingNoteCreate = true
                    }
                    quickActionCard(title: "Nuova sottocartella", subtitle: "Organizza", icon: "folder.badge.plus", color: DesignColor.success) {
                        showingNewFolderSheet = true
                    }
                    quickActionCard(title: "Importa PDF", subtitle: "In \(folder.name)", icon: "doc.badge.plus", color: DesignColor.toolWolfram) {
                        showingPDFImporter = true
                    }
                }

                if !subfolders.isEmpty {
                    VStack(alignment: .leading, spacing: DesignSpace.s3) {
                        Text("SOTTOCARTELLE")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(DesignColor.textTertiary)

                        switch viewMode {
                        case .grid:
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: DesignSpace.s4)], spacing: DesignSpace.s4) {
                                ForEach(subfolders) { subfolder in
                                    Button {
                                        selectedNote = nil
                                        selectedFolder = subfolder
                                    } label: {
                                        folderCard(subfolder)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        case .list:
                            VStack(spacing: 1) {
                                ForEach(subfolders) { subfolder in
                                    Button {
                                        selectedNote = nil
                                        selectedFolder = subfolder
                                    } label: {
                                        folderListRow(subfolder)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: DesignSpace.s3) {
                    Text("NOTE")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(DesignColor.textTertiary)

                    if notes.isEmpty {
                        Text("Nessuna nota qui ancora.")
                            .font(.system(size: 13))
                            .foregroundStyle(DesignColor.textTertiary)
                    } else {
                        switch viewMode {
                        case .grid:
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: DesignSpace.s4)], spacing: DesignSpace.s4) {
                                ForEach(notes) { note in
                                    Button {
                                        selectedFolder = nil
                                        selectedNote = note
                                    } label: {
                                        noteCard(note)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        case .list:
                            VStack(spacing: 1) {
                                ForEach(notes) { note in
                                    Button {
                                        selectedFolder = nil
                                        selectedNote = note
                                    } label: {
                                        noteListRow(note)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
                        }
                    }
                }
            }
            .padding(DesignSpace.s6)
        }
        .background(DesignColor.surfacePage)
        .navigationTitle("")
        .sheet(isPresented: $showingNoteCreate) {
            NoteCreateSheet(preselectedFolder: folder) { note in
                selectedFolder = nil
                selectedNote = note
            }
        }
        .sheet(isPresented: $showingNewFolderSheet) {
            FolderEditSheet(mode: .new(parent: folder)) { name, color, mode in
                guard case .new(let parent) = mode else { return }
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                let newFolder = Folder(name: trimmed, parent: parent, color: color)
                context.insert(newFolder)
            }
        }
        // Stesso flusso dell'Importa PDF della Home, ma la nota nasce
        // dentro QUESTA cartella invece che senza cartella.
        .fileImporter(isPresented: $showingPDFImporter, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            let title = url.deletingPathExtension().lastPathComponent
            let note = Note(title: title.isEmpty ? "Nuova nota" : title, folder: folder)
            context.insert(note)
            note.appendPages(fromPDF: data, in: context)
            selectedFolder = nil
            selectedNote = note
        }
    }


    private var viewModePicker: some View {
        HStack(spacing: 2) {
            ForEach([FolderViewMode.grid, .list], id: \.self) { mode in
                Button {
                    viewModeRaw = mode.rawValue
                } label: {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(viewMode == mode ? DesignColor.brandPrimary : DesignColor.textTertiary)
                        .frame(width: 30, height: 30)
                        .background(
                            viewMode == mode ? DesignColor.brandPrimarySubtle : Color.clear,
                            in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
    }

    @ViewBuilder
    private func folderListRow(_ subfolder: Folder) -> some View {
        HStack(spacing: DesignSpace.s3) {
            Image(systemName: "folder.fill")
                .font(.system(size: 15))
                .foregroundStyle(subfolder.folderColor.color)
                .frame(width: 22)
            Text(subfolder.name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignColor.textPrimary)
            Spacer()
            Text("\(subfolder.notes.count) note")
                .font(.system(size: 12))
                .foregroundStyle(DesignColor.textTertiary)
        }
        .padding(.horizontal, DesignSpace.s3 + 2)
        .padding(.vertical, DesignSpace.s3)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func noteListRow(_ note: Note) -> some View {
        HStack(spacing: DesignSpace.s3) {
            Image(systemName: "note.text")
                .font(.system(size: 15))
                .foregroundStyle(DesignColor.textSecondary)
                .frame(width: 22)
            Text(note.title.isEmpty ? "Senza titolo" : note.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignColor.textPrimary)
            Spacer()
            Text(note.updatedAt.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 12))
                .foregroundStyle(DesignColor.textTertiary)
        }
        .padding(.horizontal, DesignSpace.s3 + 2)
        .padding(.vertical, DesignSpace.s3)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func quickActionCard(title: String, subtitle: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DesignSpace.s3) {
                RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                    .fill(color.opacity(0.12))
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundStyle(color))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignColor.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColor.textTertiary)
                }
            }
            .padding(DesignSpace.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func folderCard(_ subfolder: Folder) -> some View {
        HStack(spacing: DesignSpace.s3) {
            Image(systemName: "folder.fill")
                .font(.system(size: 20))
                .foregroundStyle(subfolder.folderColor.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(subfolder.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignColor.textPrimary)
                    .lineLimit(1)
                Text("\(subfolder.notes.count) note")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColor.textTertiary)
            }
            Spacer()
        }
        .padding(DesignSpace.s4)
        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
    }

    @ViewBuilder
    private func noteCard(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: DesignSpace.s2) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                    .fill(Color.white)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<4, id: \.self) { _ in
                        Rectangle().fill(DesignColor.borderSubtle).frame(height: 1)
                    }
                }
                .padding(10)
            }
            .frame(height: 90)
            .overlay(RoundedRectangle(cornerRadius: DesignRadius.sm).stroke(DesignColor.borderDefault))

            Text(note.title.isEmpty ? "Senza titolo" : note.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)
                .lineLimit(1)
        }
        .padding(DesignSpace.s3)
        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
    }
}
