import SwiftUI
import SwiftData

struct ResearchPaper: Identifiable {
    let id = UUID()
    var title: String
    var authors: String
    var summary: String
    var link: URL?
    // PDF dichiarato dalla fonte (OpenAlex lo dà solo per l'accesso
    // aperto). Su arXiv non serve: si ricava dall'URL della scheda.
    var pdfURL: URL? = nil
    // Da quale indice arriva: non è più una scelta dell'utente ma
    // un'etichetta sul risultato.
    var origin: PaperOrigin = .arxiv

    // arXiv usa uno schema di URL prevedibile: .../abs/XXXX -> .../pdf/XXXX
    var pdfLink: URL? {
        if let pdfURL { return pdfURL }
        guard let link, link.absoluteString.contains("/abs/") else { return nil }
        return URL(string: link.absoluteString.replacingOccurrences(of: "/abs/", with: "/pdf/"))
    }
}

// Da dove arriva un risultato. NON è più un selettore: una ricerca
// interroga entrambi gli indici e mescola gli esiti, perché scegliere la
// fonte prima di sapere cosa c'è era una decisione che l'utente non
// aveva gli elementi per prendere. Resta come etichetta sulla riga, che
// serve invece a leggere il risultato (un preprint non è un articolo
// peer-reviewed).
//
// Google Scholar NON ha un'API pubblica e blocca attivamente le ricerche
// automatiche (CAPTCHA dopo poche chiamate): interrogarlo dall'app non è
// una cosa che si può far funzionare in modo affidabile, né lecitamente.
// Il suo equivalente aperto è OpenAlex — stesso indice di riviste,
// conferenze e citazioni, gratuito e senza chiave, quindi in linea col
// vincolo che i costi non scalino sullo sviluppatore. Scholar resta
// raggiungibile come rimando al browser (vedi `scholarWebURL`).
enum PaperOrigin: String {
    case arxiv, openAlex

    var label: String {
        switch self {
        case .arxiv: "Preprint"
        case .openAlex: "Rivista"
        }
    }

    var tint: Color {
        switch self {
        case .arxiv: DesignColor.toolLatex
        case .openAlex: DesignColor.toolExplain
        }
    }

    var tintBackground: Color {
        switch self {
        case .arxiv: DesignColor.toolLatexBg
        case .openAlex: DesignColor.toolExplainBg
        }
    }
}

@Observable
final class PaperSearchModel {
    var query = ""
    var results: [ResearchPaper] = []
    var isSearching = false
    var errorMessage: String?

    // Query aperta su Google Scholar nel browser: l'app non lo interroga
    // (non si può), ma la ricerca già scritta non va ribattuta a mano.
    var scholarWebURL: URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://scholar.google.com/scholar?q=\(encoded)")
    }

    // Una ricerca, due indici interrogati INSIEME. Le due liste vengono
    // poi alternate invece che accodate: ciascuna arriva già ordinata
    // per pertinenza dalla sua API, e concatenarle seppellirebbe la
    // seconda sotto venti risultati dell'altra.
    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        async let arxiv = Self.fetchArxiv(encoded)
        async let openAlex = Self.fetchOpenAlex(encoded)
        let (preprints, journals) = await (arxiv, openAlex)

        // Se una sola fonte cade, l'altra si mostra comunque: un indice
        // irraggiungibile non deve azzerare una ricerca riuscita a metà.
        results = Self.interleave(preprints ?? [], journals ?? [])
        if results.isEmpty {
            errorMessage = (preprints == nil && journals == nil)
                ? "Ricerca non riuscita. Controlla la connessione."
                : "Nessun risultato."
        }
    }

    // nil = la fonte non ha risposto (rete, servizio giù); [] = ha
    // risposto e non ha trovato nulla. La differenza serve al messaggio.
    private static func fetchArxiv(_ encoded: String) async -> [ResearchPaper]? {
        guard let url = URL(string: "https://export.arxiv.org/api/query?search_query=all:\(encoded)&max_results=20") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return ArxivFeedParser.parse(data)
    }

    private static func fetchOpenAlex(_ encoded: String) async -> [ResearchPaper]? {
        guard let url = URL(string: "https://api.openalex.org/works?search=\(encoded)&per_page=20") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return OpenAlexResponse.papers(from: data)
    }

    private static func interleave(_ first: [ResearchPaper], _ second: [ResearchPaper]) -> [ResearchPaper] {
        var merged: [ResearchPaper] = []
        merged.reserveCapacity(first.count + second.count)
        // Lo stesso lavoro può stare in entrambi gli indici (un preprint
        // arXiv poi pubblicato): si tiene la prima occorrenza, che per
        // costruzione è quella meglio posizionata.
        var seenTitles: Set<String> = []
        for index in 0..<max(first.count, second.count) {
            for candidate in [first.dropFirst(index).first, second.dropFirst(index).first] {
                guard let paper = candidate else { continue }
                let key = paper.title.lowercased().filter { !$0.isWhitespace }
                guard seenTitles.insert(key).inserted else { continue }
                merged.append(paper)
            }
        }
        return merged
    }
}

// Risposta di OpenAlex, ridotta ai campi che servono a una riga di
// risultato: titolo, autori, anno, rivista, scheda e — solo per
// l'accesso aperto — il PDF.
private struct OpenAlexResponse: Decodable {
    var results: [Work]

    struct Work: Decodable {
        var display_name: String?
        var publication_year: Int?
        var doi: String?
        var authorships: [Authorship]?
        var primary_location: Location?
        var best_oa_location: Location?
        var open_access: OpenAccess?
    }

    struct Authorship: Decodable {
        var author: Author?
        struct Author: Decodable { var display_name: String? }
    }

    struct Location: Decodable {
        var pdf_url: String?
        var landing_page_url: String?
        var source: Source?
        struct Source: Decodable { var display_name: String? }
    }

    struct OpenAccess: Decodable {
        var oa_url: String?
    }

    static func papers(from data: Data) -> [ResearchPaper] {
        guard let decoded = try? JSONDecoder().decode(OpenAlexResponse.self, from: data) else { return [] }
        return decoded.results.compactMap { work in
            guard let title = work.display_name?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            // Sottotitolo alla Scholar: primi autori, anno, rivista.
            let names = (work.authorships ?? []).compactMap { $0.author?.display_name }
            var parts: [String] = []
            if !names.isEmpty {
                parts.append(names.prefix(4).joined(separator: ", ") + (names.count > 4 ? " et al." : ""))
            }
            if let year = work.publication_year { parts.append(String(year)) }
            if let venue = work.primary_location?.source?.display_name { parts.append(venue) }

            let landing = work.doi
                ?? work.primary_location?.landing_page_url
                ?? work.best_oa_location?.landing_page_url
            let pdf = work.best_oa_location?.pdf_url
                ?? work.primary_location?.pdf_url
                ?? work.open_access?.oa_url

            // Un oa_url può puntare alla pagina dell'editore invece che al
            // file: lo si offre come PDF solo se lo è davvero, altrimenti
            // l'import si porterebbe dentro una pagina HTML.
            let pdfURL: URL? = {
                guard let pdf, pdf.lowercased().contains("pdf") else { return nil }
                return URL(string: pdf)
            }()

            return ResearchPaper(
                title: title,
                authors: parts.joined(separator: " · "),
                summary: "",
                link: landing.flatMap(URL.init),
                pdfURL: pdfURL,
                origin: .openAlex
            )
        }
    }
}

// Paper consultato di recente (PDF aperto o aggiunto a una nota).
// Cronologia di sola consultazione: vive in UserDefaults come JSON,
// niente SwiftData — non è un dato dell'utente da sincronizzare.
struct RecentPaper: Codable, Identifiable, Equatable {
    var title: String
    var authors: String
    var link: URL?
    var viewedAt: Date
    // Assente nelle voci salvate prima delle fonti non-arXiv: manca la
    // chiave e si decodifica a nil, che è esattamente il vecchio
    // comportamento (PDF ricavato dall'URL della scheda).
    var pdfURL: URL?

    var id: String { link?.absoluteString ?? title }
}

enum RecentPapersStore {
    private static let key = "researchRecentPapers"
    private static let maxCount = 8

    static func load() -> [RecentPaper] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([RecentPaper].self, from: data) else { return [] }
        return list
    }

    // In testa, senza duplicati (rivedere un paper lo riporta su).
    static func record(_ paper: ResearchPaper) -> [RecentPaper] {
        let entry = RecentPaper(title: paper.title, authors: paper.authors, link: paper.link, viewedAt: .now, pdfURL: paper.pdfURL)
        var list = load().filter { $0.id != entry.id }
        list.insert(entry, at: 0)
        list = Array(list.prefix(maxCount))
        save(list)
        return list
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func save(_ list: [RecentPaper]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// Paper fissati dall'utente: stessa forma dei recenti (RecentPaper) ma
// lista separata, senza cap e senza rotazione — restano finché non si
// tolgono. Anche questa in UserDefaults: è una scorciatoia, non un dato.
enum PinnedPapersStore {
    private static let key = "researchPinnedPapers"

    static func load() -> [RecentPaper] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([RecentPaper].self, from: data) else { return [] }
        return list
    }

    static func toggle(_ paper: ResearchPaper) -> [RecentPaper] {
        let entry = RecentPaper(title: paper.title, authors: paper.authors, link: paper.link, viewedAt: .now, pdfURL: paper.pdfURL)
        var list = load()
        if list.contains(where: { $0.id == entry.id }) {
            list.removeAll { $0.id == entry.id }
        } else {
            list.insert(entry, at: 0)
        }
        guard let data = try? JSONEncoder().encode(list) else { return list }
        UserDefaults.standard.set(data, forKey: key)
        return list
    }
}

// Contenuto condiviso: usato sia dal pannello Strumenti (dentro una nota,
// come sheet) sia dall'ambiente "Ricerca" a tutta pagina nella sidebar.
// Layout dal mock ResearchScreen.jsx del design system: colonna centrata
// (max 640), righe con tile icona 36×36 e separatori sottili.
struct ResearchContentView: View {
    @Bindable var model: PaperSearchModel
    var onImported: (Note) -> Void = { _ in }
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL

    @State private var pendingPaper: ResearchPaper?
    // Presentazione separata dai dati: vedi nota in WebeepEnvironmentView —
    // il Binding calcolato azzerava pendingPaper prima che il Task lo leggesse.
    @State private var showingImportChoice = false
    @State private var showingNotePicker = false
    @State private var isImporting = false
    @State private var recents: [RecentPaper] = RecentPapersStore.load()
    @State private var pinned: [RecentPaper] = PinnedPapersStore.load()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpace.s5) {
                searchField
                sourceNote

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(DesignFont.caption)
                        .foregroundStyle(DesignColor.textSecondary)
                        .padding(.horizontal, DesignSpace.s1)
                }

                if !model.results.isEmpty {
                    resultsSection
                } else if !model.isSearching {
                    if !pinned.isEmpty {
                        pinnedSection
                    }
                    if !visibleRecents.isEmpty {
                        recentsSection
                    }
                    if pinned.isEmpty && visibleRecents.isEmpty {
                        emptyState
                    }
                }
            }
            .padding(.horizontal, DesignSpace.s6)
            .padding(.vertical, DesignSpace.s6)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(DesignColor.surfacePage)
        .confirmationDialog(
            "Come vuoi aggiungere questo paper?",
            isPresented: $showingImportChoice,
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
    }

    // MARK: - Sottoviste

    // Niente più selettore di fonte: la ricerca interroga entrambi gli
    // indici e mescola. Qui resta la nota su cosa copre la ricerca e il
    // rimando a Scholar, che l'app non può interrogare ma può aprire con
    // la query già scritta.
    private var sourceNote: some View {
        HStack(alignment: .center, spacing: DesignSpace.s2) {
            Text("Preprint (arXiv) e articoli di riviste e conferenze (OpenAlex), insieme.")
                .font(DesignFont.caption)
                .foregroundStyle(DesignColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let scholarURL = model.scholarWebURL {
                Button {
                    openURL(scholarURL)
                } label: {
                    Label("Cerca su Scholar", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(PaperActionStyle())
                .accessibilityLabel("Apri questa ricerca su Google Scholar nel browser")
            }
        }
        .padding(.horizontal, DesignSpace.s1)
    }

    private var searchField: some View {
        HStack(spacing: DesignSpace.s2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DesignIcon.md))
                .foregroundStyle(DesignColor.textTertiary)
            TextField("Cerca un paper (es. neural networks)", text: $model.query)
                .textFieldStyle(.plain)
                .font(DesignFont.body)
                .submitLabel(.search)
                .onSubmit { Task { await model.search() } }
            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !model.query.isEmpty {
                Button {
                    model.query = ""
                    model.results = []
                    model.errorMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: DesignIcon.md))
                        .foregroundStyle(DesignColor.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Svuota ricerca")
            }
        }
        .padding(.horizontal, DesignSpace.s3)
        .padding(.vertical, DesignSpace.s3)
        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
                .strokeBorder(DesignColor.borderSubtle)
        )
    }

    // I recenti già fissati non si ripetono sotto: vivono nella sezione
    // "Fissati" finché restano tali.
    private var visibleRecents: [RecentPaper] {
        let pinnedIDs = Set(pinned.map(\.id))
        return recents.filter { !pinnedIDs.contains($0.id) }
    }

    private func isPinned(id: String) -> Bool {
        pinned.contains { $0.id == id }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s2) {
            sectionHeader("Risultati")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.results) { paper in
                    paperRow(for: paper, tileIcon: "doc.text")
                    if paper.id != model.results.last?.id {
                        Divider().overlay(DesignColor.borderSubtle)
                    }
                }
            }
        }
    }

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s2) {
            sectionHeader("Fissati")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(pinned) { entry in
                    paperRow(for: entry.asPaper, tileIcon: "pin")
                    if entry.id != pinned.last?.id {
                        Divider().overlay(DesignColor.borderSubtle)
                    }
                }
            }
        }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s2) {
            HStack {
                sectionHeader("Visti di recente")
                Spacer()
                Button("Svuota") {
                    RecentPapersStore.clear()
                    recents = []
                }
                .font(DesignFont.action)
                .foregroundStyle(DesignColor.textTertiary)
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(visibleRecents) { recent in
                    paperRow(for: recent.asPaper, tileIcon: "clock")
                    if recent.id != visibleRecents.last?.id {
                        Divider().overlay(DesignColor.borderSubtle)
                    }
                }
            }
        }
    }

    // Riga unica per risultati, fissati e recenti: cambia solo l'icona del
    // tile, così pin/import/apri si comportano identici ovunque.
    private func paperRow(for paper: ResearchPaper, tileIcon: String) -> some View {
        let rowID = paper.link?.absoluteString ?? paper.title
        return PaperRow(
            title: paper.title,
            subtitle: paper.authors,
            tileIcon: tileIcon,
            isPinned: isPinned(id: rowID),
            canImport: paper.pdfLink != nil && !isImporting,
            // Senza accesso aperto il PDF non esiste: si apre la scheda
            // dell'editore, da cui si passa dalla biblioteca del Poli.
            openLabel: paper.pdfLink != nil ? "Apri PDF" : "Apri scheda",
            onTogglePin: {
                withAnimation(.snappy(duration: 0.2)) {
                    pinned = PinnedPapersStore.toggle(paper)
                }
            },
            onOpenPDF: (paper.pdfLink ?? paper.link).map { url in
                { openPDF(url, recording: paper) }
            },
            onImport: {
                pendingPaper = paper
                showingImportChoice = true
            },
            origin: paper.origin
        )
    }

    private var emptyState: some View {
        BoostState(
            kind: .empty,
            icon: "doc.text.magnifyingglass",
            title: "Cerca preprint e articoli",
            message: "I paper che apri o aggiungi a una nota compariranno qui, tra i visti di recente."
        )
        .padding(.top, DesignSpace.s8)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(DesignFont.micro)
            .tracking(0.6)
            .foregroundStyle(DesignColor.textTertiary)
            .padding(.horizontal, DesignSpace.s1)
    }

    private func openPDF(_ url: URL, recording paper: ResearchPaper) {
        recents = RecentPapersStore.record(paper)
        openURL(url)
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
            BoostToastCenter.shared.show("Non sono riuscito a scaricare il PDF di \"\(paper.title)\". Controlla la connessione e riprova.", role: .danger)
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
        guard note.appendPages(fromPDF: data, in: context) else {
            if case .newNote = target { context.delete(note) }
            BoostToastCenter.shared.show("Il PDF di \"\(paper.title)\" non è leggibile. Riprova più tardi.", role: .danger)
            return
        }
        note.updatedAt = .now
        recents = RecentPapersStore.record(paper)
        onImported(note)
    }
}

extension RecentPaper {
    // Per riusare il flusso di import esistente (che lavora su ResearchPaper).
    var asPaper: ResearchPaper {
        ResearchPaper(title: title, authors: authors, summary: "", link: link, pdfURL: pdfURL)
    }

    var pdfLink: URL? { asPaper.pdfLink }
}

// Riga paper dal mock: tile icona 36×36 su surfaceSunken, titolo 14
// semibold, autori 12 terziario, azioni come pill sotto.
private struct PaperRow: View {
    var title: String
    var subtitle: String
    var tileIcon: String
    var isPinned: Bool
    var canImport: Bool
    var openLabel: String = "Apri PDF"
    var onTogglePin: () -> Void
    var onOpenPDF: (() -> Void)?
    var onImport: () -> Void
    // nil per le righe di cronologia: la provenienza non viene salvata
    // fra le voci recenti, e inventarla sarebbe peggio che ometterla.
    var origin: PaperOrigin? = nil

    var body: some View {
        HStack(alignment: .top, spacing: DesignSpace.s3 + 2) {
            RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                .fill(DesignColor.surfaceSunken)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: tileIcon)
                        .font(.system(size: DesignIcon.md))
                        .foregroundStyle(DesignColor.textSecondary)
                )

            VStack(alignment: .leading, spacing: DesignSpace.s1) {
                Text(title)
                    .font(DesignFont.cardTitle)
                    .foregroundStyle(DesignColor.textPrimary)
                    .lineLimit(3)
                HStack(spacing: DesignSpace.s2) {
                    // Da quale indice arriva. Non è un dettaglio tecnico:
                    // dice se stai guardando un preprint o un articolo
                    // pubblicato, che è la prima cosa da sapere per
                    // citarlo.
                    if let origin {
                        Text(origin.label.uppercased())
                            .font(DesignFont.micro)
                            .tracking(0.4)
                            .foregroundStyle(origin.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(origin.tintBackground, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
                    }
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(DesignFont.caption)
                            .foregroundStyle(DesignColor.textTertiary)
                            .lineLimit(2)
                    }
                }

                HStack(spacing: DesignSpace.s2) {
                    if let onOpenPDF {
                        Button(action: onOpenPDF) {
                            Label(openLabel, systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(PaperActionStyle())
                    }
                    Button(action: onImport) {
                        Label("Aggiungi a nota", systemImage: "plus.circle")
                    }
                    .buttonStyle(PaperActionStyle())
                    .disabled(!canImport)
                }
                .padding(.top, DesignSpace.s1)
            }

            Spacer(minLength: 0)

            Button(action: onTogglePin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: DesignIcon.md))
                    .foregroundStyle(isPinned ? DesignColor.brandPrimary : DesignColor.textTertiary)
                    .frame(width: 28, height: 28)
                    .background(
                        isPinned ? DesignColor.brandPrimarySubtle : .clear,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPinned ? "Togli dai fissati" : "Fissa il paper")
        }
        .padding(.vertical, DesignSpace.s3 + 2)
        .padding(.horizontal, DesignSpace.s1)
    }
}

// Pill compatta per le azioni di riga: brand su fondo brand tenue.
private struct PaperActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignFont.action)
            .foregroundStyle(isEnabled ? DesignColor.brandPrimary : DesignColor.textTertiary)
            .padding(.horizontal, DesignSpace.s3)
            .padding(.vertical, 6)
            .background(
                isEnabled ? DesignColor.brandPrimarySubtle : DesignColor.surfaceSunken,
                in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// Elenco di tutte le note per scegliere dove aggiungere un paper.
private struct ResearchNotePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Note.updatedAt, order: .reverse) private var allNotes: [Note]
    var onSelect: (Note) -> Void

    // Il tocco seleziona, «Aggiungi» conferma: stessa meccanica di ogni
    // sheet commit (§4), invece dell'esecuzione al tocco.
    @State private var selectedNoteID: UUID?

    var body: some View {
        BoostSheet(
            title: "Scegli una nota",
            mode: .commit(verb: "Aggiungi", enabled: selectedNoteID != nil),
            onDismiss: { dismiss() },
            onConfirm: {
                if let note = allNotes.first(where: { $0.id == selectedNoteID }) {
                    onSelect(note)
                }
            }
        ) {
            List(allNotes) { note in
                let isSelected = selectedNoteID == note.id
                Button {
                    selectedNoteID = isSelected ? nil : note.id
                } label: {
                    HStack(spacing: DesignSpace.s3) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? DesignColor.brandPrimary : DesignColor.borderDefault)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title.isEmpty ? "Senza titolo" : note.title)
                                .foregroundStyle(.primary)
                            if let folder = note.folder {
                                Text(folder.name)
                                    .font(DesignFont.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// Parsing minimale del feed Atom restituito dall'API di arXiv.
private enum ArxivFeedParser {
    static func parse(_ data: Data) -> [ResearchPaper] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.papers
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var papers: [ResearchPaper] = []
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
                papers.append(ResearchPaper(
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
