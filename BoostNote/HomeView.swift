import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// Schermata Home: saluto, azioni rapide (nuova nota / cartella / importa
// PDF) e griglia delle note recenti — landing dell'ambiente "Note".
struct HomeView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("profileName") private var profileName = ""
    @Binding var selectedNote: Note?

    @Query(sort: \Note.updatedAt, order: .reverse) private var allNotes: [Note]

    @AppStorage("homeViewMode") private var viewModeRaw = FolderViewMode.grid.rawValue
    private var viewMode: FolderViewMode { FolderViewMode(rawValue: viewModeRaw) ?? .grid }

    @State private var showingNoteCreate = false
    @State private var showingNewFolderSheet = false
    @State private var showingPDFImporter = false

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let base = hour < 12 ? "Buongiorno" : (hour < 18 ? "Buon pomeriggio" : "Buonasera")
        let trimmedName = profileName.trimmingCharacters(in: .whitespaces)
        return trimmedName.isEmpty ? base : "\(base), \(trimmedName)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpace.s8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(greeting)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(DesignColor.textPrimary)
                        Image(systemName: "sparkles")
                            .foregroundStyle(DesignColor.brandPrimary)
                    }
                    Text(Date.now.formatted(date: .long, time: .omitted))
                        .font(.system(size: 14))
                        .foregroundStyle(DesignColor.textTertiary)
                }

                HStack(spacing: DesignSpace.s4) {
                    quickActionCard(title: "Nuova nota", subtitle: "Canvas vuoto", icon: "square.and.pencil", color: DesignColor.brandPrimary) {
                        showingNoteCreate = true
                    }
                    quickActionCard(title: "Nuova cartella", subtitle: "Organizza", icon: "folder.badge.plus", color: DesignColor.success) {
                        showingNewFolderSheet = true
                    }
                    quickActionCard(title: "Importa PDF", subtitle: "Come foglio o widget", icon: "doc.badge.plus", color: DesignColor.toolWolfram) {
                        showingPDFImporter = true
                    }
                }

                if !allNotes.isEmpty {
                    VStack(alignment: .leading, spacing: DesignSpace.s3) {
                        HStack {
                            Text("RECENTI")
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(DesignColor.textTertiary)
                            Spacer()
                            viewModePicker
                        }

                        switch viewMode {
                        case .grid:
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: DesignSpace.s4)], spacing: DesignSpace.s4) {
                                ForEach(allNotes.prefix(12)) { note in
                                    Button {
                                        selectedNote = note
                                    } label: {
                                        recentNoteCard(note)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        case .list:
                            VStack(spacing: 1) {
                                ForEach(allNotes.prefix(12)) { note in
                                    Button {
                                        selectedNote = note
                                    } label: {
                                        recentNoteListRow(note)
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
            NoteCreateSheet(preselectedFolder: nil) { note in
                selectedNote = note
            }
        }
        .sheet(isPresented: $showingNewFolderSheet) {
            FolderEditSheet(mode: .new(parent: nil)) { name, color, mode in
                guard case .new(let parent) = mode else { return }
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                let folder = Folder(name: trimmed, parent: parent, color: color)
                context.insert(folder)
            }
        }
        .fileImporter(isPresented: $showingPDFImporter, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            let title = url.deletingPathExtension().lastPathComponent
            let note = Note(title: title.isEmpty ? "Nuova nota" : title, folder: nil)
            context.insert(note)
            note.appendPages(fromPDF: data, in: context)
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
    private func recentNoteListRow(_ note: Note) -> some View {
        HStack(spacing: DesignSpace.s3) {
            Image(systemName: "note.text")
                .font(.system(size: 15))
                .foregroundStyle(DesignColor.textSecondary)
                .frame(width: 22)
            Text(note.title.isEmpty ? "Senza titolo" : note.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignColor.textPrimary)
            if let folder = note.folder {
                Label(folder.name, systemImage: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignColor.textTertiary)
            }
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
    private func recentNoteCard(_ note: Note) -> some View {
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
            if let folder = note.folder {
                Label(folder.name, systemImage: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignColor.textTertiary)
            }
        }
        .padding(DesignSpace.s3)
        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
    }
}
