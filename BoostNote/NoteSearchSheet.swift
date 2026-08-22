import SwiftUI
import UIKit

// Risultato di ricerca: pagina virtuale in cui è stato trovato il testo,
// e un frammento di contesto attorno alla corrispondenza.
private struct NoteSearchResult: Identifiable {
    let id = UUID()
    var pageIndex: Int
    var snippet: String
    // Intervallo della corrispondenza dentro `snippet`, per evidenziarla.
    var matchRange: Range<String.Index>?
    var source: Source

    enum Source { case typed, handwriting }
}

// Pannello di ricerca nella nota: cerca nel testo digitato (istantaneo) e
// nella scrittura a mano (OCR pagina per pagina, più lento).
//
// Cose che qui erano rotte e sono state sistemate:
// - la ricerca partiva SOLO premendo Invio; ora è dal vivo mentre si
//   scrive, con una pausa per non ricalcolare a ogni lettera;
// - l'OCR girava sulla miniatura della pagina così com'era: se il canvas
//   ha sfondo trasparente Vision non riconosce NULLA (stesso problema già
//   trovato sull'estrazione delle note). Ora la pagina viene composta su
//   bianco prima del riconoscimento;
// - il frammento mostrato era l'INTERO testo riconosciuto della pagina,
//   troncato a due righe: non si vedeva mai la parte che corrispondeva.
//   Ora si estrae il contesto attorno alla corrispondenza e la si
//   evidenzia;
// - ogni ricerca rifaceva l'OCR di tutte le pagine: ora il risultato per
//   pagina viene tenuto in cache finché il pannello resta aperto.
struct NoteSearchSheet: View {
    var note: Note
    var drawingController: DrawingController
    var pageWidth: CGFloat
    var pageHeight: CGFloat
    var onJumpToPage: (Int) -> Void

    @State private var query = ""
    @State private var results: [NoteSearchResult] = []
    @State private var ocrCache: [Int: String] = [:]
    @State private var scanningPage: Int?
    @State private var totalPages = 0
    @State private var searchTask: Task<Void, Never>?

    private var typedResults: [NoteSearchResult] { results.filter { $0.source == .typed } }
    private var handwritingResults: [NoteSearchResult] { results.filter { $0.source == .handwriting } }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
        }
        // Su iPad è un popover a misura fissa; su iPhone diventa uno
        // sheet e deve riempire lo spazio che il detent gli dà.
        .frame(
            width: DeviceLayout.isPhone ? nil : 380,
            height: DeviceLayout.isPhone ? nil : 460
        )
        .frame(maxWidth: DeviceLayout.isPhone ? .infinity : nil, maxHeight: DeviceLayout.isPhone ? .infinity : nil)
        .background(DesignColor.surfacePage)
        .onChange(of: query) { _, _ in scheduleSearch() }
        .onDisappear { searchTask?.cancel() }
    }

    private var searchField: some View {
        HStack(spacing: DesignSpace.s2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(DesignColor.textTertiary)
            TextField("Cerca nella nota", text: $query)
                .font(.system(size: 15))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(DesignColor.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DesignSpace.s3)
    }

    @ViewBuilder
    private var content: some View {
        if trimmedQuery.isEmpty {
            hint
        } else if results.isEmpty && scanningPage == nil {
            ContentUnavailableView(
                "Nessun risultato",
                systemImage: "magnifyingglass",
                description: Text("Né nel testo digitato né nella scrittura a mano.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpace.s4) {
                    if !typedResults.isEmpty {
                        resultSection(title: "TESTO", icon: "textformat", results: typedResults)
                    }
                    if !handwritingResults.isEmpty {
                        resultSection(title: "SCRITTURA A MANO", icon: "scribble", results: handwritingResults)
                    }
                    if let scanningPage {
                        HStack(spacing: DesignSpace.s2) {
                            ProgressView().controlSize(.mini)
                            Text("Leggo la scrittura a mano — pagina \(scanningPage + 1) di \(totalPages)")
                                .font(.system(size: 11))
                                .foregroundStyle(DesignColor.textTertiary)
                        }
                        .padding(.horizontal, DesignSpace.s3)
                    }
                }
                .padding(.vertical, DesignSpace.s3)
            }
        }
    }

    private var hint: some View {
        VStack(spacing: DesignSpace.s3) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(DesignColor.textTertiary)
            Text("Cerca nella nota")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)
            Text("Trova sia il testo che hai digitato sia quello scritto a mano. La scrittura richiede qualche secondo per essere riconosciuta.")
                .font(.system(size: 12))
                .foregroundStyle(DesignColor.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSpace.s5)
        }
        .frame(maxHeight: .infinity)
    }

    private func resultSection(title: String, icon: String, results: [NoteSearchResult]) -> some View {
        VStack(alignment: .leading, spacing: DesignSpace.s2) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                Text("\(results.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignColor.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
            }
            .foregroundStyle(DesignColor.textSecondary)
            .padding(.horizontal, DesignSpace.s3)

            ForEach(results) { result in
                Button {
                    onJumpToPage(result.pageIndex)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(highlighted(result))
                            .font(.system(size: 13))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        Text("Pagina \(result.pageIndex + 1)")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignColor.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DesignSpace.s3)
                    .padding(.vertical, DesignSpace.s2 + 2)
                    .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DesignSpace.s3)
            }
        }
    }

    // La corrispondenza va evidenziata: senza, in un frammento di tre
    // righe non si capisce cosa sia stato trovato.
    private func highlighted(_ result: NoteSearchResult) -> AttributedString {
        var attributed = AttributedString(result.snippet)
        attributed.foregroundColor = DesignColor.textPrimary
        if let range = result.matchRange,
           let attributedRange = Range(range, in: attributed) {
            attributed[attributedRange].foregroundColor = DesignColor.brandPrimary
            attributed[attributedRange].font = .system(size: 13, weight: .bold)
        }
        return attributed
    }

    // MARK: - Ricerca

    // Ricerca dal vivo con una breve pausa: scrivendo "integrale" senza
    // questa si farebbero nove ricerche complete, ognuna con l'OCR.
    private func scheduleSearch() {
        searchTask?.cancel()
        let current = trimmedQuery
        guard !current.isEmpty else {
            results = []
            scanningPage = nil
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search(current)
        }
    }

    private func search(_ term: String) async {
        // 1. Testo digitato: immediato, si mostra subito.
        var found: [NoteSearchResult] = []
        for box in note.textBoxes {
            if let range = box.text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                let pageIndex = pageHeight > 0 ? max(0, Int(box.y / pageHeight)) : 0
                let (snippet, snippetRange) = Self.context(around: range, in: box.text)
                found.append(NoteSearchResult(pageIndex: pageIndex, snippet: snippet, matchRange: snippetRange, source: .typed))
            }
        }
        guard !Task.isCancelled else { return }
        results = found

        // 2. Scrittura a mano: OCR pagina per pagina, con i risultati che
        // compaiono man mano invece di far aspettare la fine.
        let pageCount = drawingController.pageCount(pageHeight: pageHeight)
        totalPages = pageCount
        for index in 0..<pageCount {
            guard !Task.isCancelled else { return }
            scanningPage = index

            let recognized: String
            if let cached = ocrCache[index] {
                recognized = cached
            } else {
                guard let raw = drawingController.pageThumbnail(index: index, pageWidth: pageWidth, pageHeight: pageHeight) else { continue }
                // La miniatura può avere sfondo trasparente, e su quella
                // Vision non riconosce nulla: si compone su bianco.
                let image = Self.onWhite(raw)
                recognized = await MagicPenService.recognizeText(in: image) ?? ""
                guard !Task.isCancelled else { return }
                ocrCache[index] = recognized
            }

            if let range = recognized.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                let (snippet, snippetRange) = Self.context(around: range, in: recognized)
                found.append(NoteSearchResult(pageIndex: index, snippet: snippet, matchRange: snippetRange, source: .handwriting))
                results = found
            }
        }
        scanningPage = nil
    }

    // Frammento attorno alla corrispondenza invece dell'intero testo
    // della pagina, con l'intervallo ricalcolato sul frammento.
    private static func context(around range: Range<String.Index>, in text: String, padding: Int = 60) -> (String, Range<String.Index>?) {
        let start = text.index(range.lowerBound, offsetBy: -padding, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: padding, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if start > text.startIndex { snippet = "…" + snippet }
        if end < text.endIndex { snippet += "…" }
        let matched = String(text[range])
        return (snippet, snippet.range(of: matched, options: [.caseInsensitive, .diacriticInsensitive]))
    }

    private static func onWhite(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: image.size))
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
