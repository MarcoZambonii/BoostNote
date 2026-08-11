import SwiftUI
import SwiftData

struct ArxivPaper: Identifiable {
    let id = UUID()
    var title: String
    var authors: String
    var summary: String
    var link: URL?

    // arXiv usa uno schema di URL prevedibile: .../abs/XXXX -> .../pdf/XXXX
    var pdfLink: URL? {
        guard let link else { return nil }
        let pdfString = link.absoluteString.replacingOccurrences(of: "/abs/", with: "/pdf/")
        return URL(string: pdfString)
    }
}

@Observable
final class ArxivSearchModel {
    var query = ""
    var results: [ArxivPaper] = []
    var isSearching = false
    var errorMessage: String?

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        guard let url = URL(string: "https://export.arxiv.org/api/query?search_query=all:\(encoded)&max_results=20") else { return }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            results = ArxivFeedParser.parse(data)
            if results.isEmpty { errorMessage = "Nessun risultato." }
        } catch {
            errorMessage = "Ricerca non riuscita. Controlla la connessione."
        }
    }
}

// Contenuto condiviso: usato sia dal pannello Strumenti (dentro una nota,
// come sheet) sia dall'ambiente "Ricerca" a tutta pagina nella sidebar.
struct ResearchContentView: View {
    @Bindable var model: ArxivSearchModel
    var onImported: (Note) -> Void = { _ in }
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    @State private var pendingPaper: ArxivPaper?
    @State private var showingNotePicker = false
    @State private var isImporting = false
    @State private var importErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSpace.s2) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DesignColor.textTertiary)
                TextField("Cerca paper (es. neural networks)", text: $model.query)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await model.search() } }
                if model.isSearching {
                    ProgressView()
                }
            }
            .padding(DesignSpace.s3)
            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
            .padding(DesignSpace.s4)

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(DesignColor.textSecondary)
                    .padding(.bottom, DesignSpace.s2)
            }

            List(model.results) { paper in
                VStack(alignment: .leading, spacing: 6) {
                    Text(paper.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignColor.textPrimary)
                    Text(paper.authors)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColor.textTertiary)

                    HStack(spacing: DesignSpace.s4) {
                        if let pdfLink = paper.pdfLink {
                            Button {
                                openURL(pdfLink)
                            } label: {
                                Label("Apri PDF", systemImage: "doc.text")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        Button {
                            pendingPaper = paper
                        } label: {
                            Label("Aggiungi a una nota", systemImage: "plus.circle")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .disabled(paper.pdfLink == nil || isImporting)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignColor.brandPrimary)
                }
                .padding(.vertical, 4)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(DesignColor.surfaceSunken)
        .confirmationDialog(
            "Come vuoi aggiungere questo paper?",
            isPresented: Binding(get: { pendingPaper != nil && !showingNotePicker }, set: { if !$0 { pendingPaper = nil } }),
            titleVisibility: .visible
        ) {
            Button("In una nuova nota") { Task { await importPaper(target: .newNote) } }
            Button("In una nota esistente") { showingNotePicker = true }
            Button("Annulla", role: .cancel) { pendingPaper = nil }
        }
        .sheet(isPresented: $showingNotePicker) {
            ResearchNotePickerSheet { note in
                showingNotePicker = false
                Task { await importPaper(target: .existingNote(note)) }
            }
        }
        .alert("Import non riuscito", isPresented: Binding(get: { importErrorMessage != nil }, set: { if !$0 { importErrorMessage = nil } })) {
            Button("OK", role: .cancel) { importErrorMessage = nil }
        } message: {
            Text(importErrorMessage ?? "")
        }
    }

    private enum ImportTarget {
        case newNote
        case existingNote(Note)
    }

    private func importPaper(target: ImportTarget) async {
        guard let paper = pendingPaper, let pdfURL = paper.pdfLink else { return }
        isImporting = true
        defer { isImporting = false; pendingPaper = nil }

        guard let (data, _) = try? await URLSession.shared.data(from: pdfURL) else {
            importErrorMessage = "Non sono riuscito a scaricare il PDF di \"\(paper.title)\". Controlla la connessione e riprova."
            return
        }

        let note: Note
        switch target {
        case .newNote:
            note = Note(title: paper.title, folder: nil)
            context.insert(note)
        case .existingNote(let existing):
            note = existing
        }
        note.appendPDFPages(from: data)
        note.updatedAt = .now
        onImported(note)
    }
}

// Elenco di tutte le note per scegliere dove aggiungere un paper.
private struct ResearchNotePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Note.updatedAt, order: .reverse) private var allNotes: [Note]
    var onSelect: (Note) -> Void

    var body: some View {
        NavigationStack {
            List(allNotes) { note in
                Button {
                    onSelect(note)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title.isEmpty ? "Senza titolo" : note.title)
                            .foregroundStyle(.primary)
                        if let folder = note.folder {
                            Text(folder.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Scegli una nota")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
    }
}

// Parsing minimale del feed Atom restituito dall'API di arXiv.
private enum ArxivFeedParser {
    static func parse(_ data: Data) -> [ArxivPaper] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.papers
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var papers: [ArxivPaper] = []
        private var currentElement = ""
        private var title = ""
        private var summary = ""
        private var authors: [String] = []
        private var link: String?
        private var insideEntry = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            currentElement = elementName
            if elementName == "entry" {
                insideEntry = true
                title = ""; summary = ""; authors = []; link = nil
            }
            if insideEntry, elementName == "link", attributeDict["type"] == "text/html" {
                link = attributeDict["href"]
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard insideEntry else { return }
            switch currentElement {
            case "title": title += string
            case "summary": summary += string
            case "name": authors.append(string)
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "entry" {
                let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanAuthors = authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: ", ")
                papers.append(ArxivPaper(
                    title: cleanTitle,
                    authors: cleanAuthors,
                    summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                    link: link.flatMap(URL.init)
                ))
                insideEntry = false
            }
        }
    }
}
