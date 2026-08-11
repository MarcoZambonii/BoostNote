import SwiftUI

// Risultato di ricerca: pagina virtuale in cui è stato trovato il testo,
// e un frammento per mostrarlo in lista.
private struct NoteSearchResult: Identifiable {
    let id = UUID()
    var pageIndex: Int
    var snippet: String
    var source: Source

    enum Source { case typed, handwriting }
}

// Pannello di ricerca ancorato alla barra fissa (come gli altri picker
// "a cascata" dell'app): cerca sia nel testo digitato (caselle di testo)
// sia nella scrittura a mano (OCR Vision pagina per pagina).
struct NoteSearchSheet: View {
    var note: Note
    var drawingController: DrawingController
    var pageWidth: CGFloat
    var pageHeight: CGFloat
    var onJumpToPage: (Int) -> Void

    @State private var query = ""
    @State private var results: [NoteSearchResult] = []
    @State private var isSearching = false
    @State private var hasSearched = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSpace.s2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignColor.textTertiary)
                TextField("Cerca testo o scrittura a mano", text: $query)
                    .font(.system(size: 14))
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await search() } }
                if isSearching {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .padding(DesignSpace.s3)
            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
            .padding(DesignSpace.s3)

            if hasSearched && !isSearching && results.isEmpty {
                ContentUnavailableView("Nessun risultato", systemImage: "magnifyingglass")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(results) { result in
                            Button {
                                onJumpToPage(result.pageIndex)
                            } label: {
                                HStack(spacing: DesignSpace.s3) {
                                    Image(systemName: result.source == .typed ? "textformat" : "scribble")
                                        .foregroundStyle(DesignColor.brandPrimary)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.snippet)
                                            .font(.system(size: 13))
                                            .foregroundStyle(DesignColor.textPrimary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Text("Pagina \(result.pageIndex + 1)")
                                            .font(.system(size: 11))
                                            .foregroundStyle(DesignColor.textTertiary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, DesignSpace.s3)
                                .padding(.vertical, DesignSpace.s2 + 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, DesignSpace.s2)
                    .padding(.bottom, DesignSpace.s3)
                }
            }
        }
        .frame(width: 320, height: 380)
        .background(DesignColor.surfacePage)
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { results = []; hasSearched = false; return }

        isSearching = true
        hasSearched = true
        defer { isSearching = false }

        var found: [NoteSearchResult] = []

        for box in note.textBoxes where box.text.localizedCaseInsensitiveContains(trimmed) {
            let pageIndex = pageHeight > 0 ? max(0, Int(box.y / pageHeight)) : 0
            found.append(NoteSearchResult(pageIndex: pageIndex, snippet: box.text, source: .typed))
        }

        let pageCount = drawingController.pageCount(pageHeight: pageHeight)
        for index in 0..<pageCount {
            guard let image = drawingController.pageThumbnail(index: index, pageWidth: pageWidth, pageHeight: pageHeight) else { continue }
            guard let recognized = await MagicPenService.recognizeText(in: image), !recognized.isEmpty else { continue }
            if recognized.localizedCaseInsensitiveContains(trimmed) {
                found.append(NoteSearchResult(pageIndex: index, snippet: recognized, source: .handwriting))
            }
        }

        results = found
    }
}
