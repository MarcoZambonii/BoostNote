import Foundation
import SwiftData
import SwiftUI
import PDFKit
import PencilKit

// MARK: - Cartella
// Rappresenta una cartella nell'organizzazione delle note.
// Supporta cartelle annidate tramite la relazione parent/children.
// NOTA CloudKit (sync iCloud, 2026-08-17): ogni proprietà persistita di
// OGNI @Model deve avere un default o essere opzionale, niente
// @Attribute(.unique), relazioni opzionali o con default. Un campo senza
// default aggiunto qui spegne il sync alla prima apertura.
@Model
final class Folder {
    var name: String = ""
    var createdAt: Date = Date.now
    var parent: Folder?

    // Colore dell'icona cartella, salvato come rawValue di FolderColor.
    // Il default qui serve alla migrazione automatica di SwiftData.
    var colorRaw: String = FolderColor.blue.rawValue

    // Le to-many sono OPZIONALI (requisito CloudKit, non basta il
    // default []): lo storage sta nella proprietà privata con
    // originalName, il wrapper calcolato conserva l'API non-opzionale
    // per tutto il resto dell'app.
    @Relationship(deleteRule: .cascade, originalName: "children", inverse: \Folder.parent)
    private var childrenStorage: [Folder]? = []
    var children: [Folder] {
        get { childrenStorage ?? [] }
        set { childrenStorage = newValue }
    }

    @Relationship(deleteRule: .cascade, originalName: "notes", inverse: \Note.folder)
    private var notesStorage: [Note]? = []
    var notes: [Note] {
        get { notesStorage ?? [] }
        set { notesStorage = newValue }
    }

    init(name: String, parent: Folder? = nil, color: FolderColor = .blue) {
        self.name = name
        self.createdAt = .now
        self.parent = parent
        self.colorRaw = color.rawValue
    }
}

extension Folder {
    var folderColor: FolderColor {
        get { FolderColor(rawValue: colorRaw) ?? .blue }
        set { colorRaw = newValue.rawValue }
    }
}

enum FolderColor: String, CaseIterable, Codable {
    case gray, blue, red, green, orange, purple, teal

    // Tavolozza DEDICATA alle cartelle, più docile dei colori degli
    // strumenti (richiesta utente 2026-08-16): prima riusava i token
    // accesi dell'app — blu elettrico, arancio Wolfram — e nella barra
    // laterale urlavano. Queste sono le stesse tinte, desaturate e
    // scurite quel tanto che basta a reggere anche come colore del
    // glifo su fondo chiaro. Solo qui: gli strumenti restano accesi.
    var color: Color {
        switch self {
        case .gray: Color(hex: 0x8A857F)
        case .blue: Color(hex: 0x6E87D8)
        case .red: Color(hex: 0xC96A5E)
        case .green: Color(hex: 0x5E9678)
        case .orange: Color(hex: 0xC08552)
        case .purple: Color(hex: 0x8B7FD0)
        case .teal: Color(hex: 0x5F9EA0)
        }
    }
}

// MARK: - Nota
// Una nota è di base un foglio a scorrimento infinito su cui si scrive
// con la penna (PencilKit). Il testo è opzionale: si inserisce con lo
// strumento "Aa" sotto forma di caselle di testo posizionate sul foglio.
@Model
final class Note {
    // UUID stabile usata per il drag-and-drop tra cartelle (NSItemProvider
    // vuole un identificatore serializzabile, non il PersistentIdentifier di SwiftData).
    var id: UUID = UUID()
    var title: String = ""
    // Testo ricavato dalle caselle di testo, usato solo per l'anteprima
    // nella lista note e per la ricerca. Non è editabile direttamente.
    var content: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var folder: Folder?

    // Caselle di testo posizionate sul foglio, serializzate come JSON.
    var textBoxesData: Data?

    // Elementi della to-do list del pannello laterale, serializzati come
    // JSON — per nota, così ogni nota mantiene la sua lista.
    var todoItemsData: Data?

    // Ultima pagina guardata: riaprendo la nota si riparte da lì, non
    // dalla prima (né dall'ultima) — come un segnalibro automatico.
    var lastViewedPage: Int = 0

    // Modello del foglio (quadretti, righe, crocette, bianco), salvato come rawValue.
    // Il default qui (non solo nell'init) serve alla migrazione automatica di SwiftData.
    var templateRaw: String = NoteTemplate.blank.rawValue

    // Immagini e PDF inseriti sul foglio. (Opzionale + wrapper: vedi la
    // nota CloudKit su Folder.)
    @Relationship(deleteRule: .cascade, originalName: "media", inverse: \NoteMedia.note)
    private var mediaStorage: [NoteMedia]? = []
    var media: [NoteMedia] {
        get { mediaStorage ?? [] }
        set { mediaStorage = newValue }
    }

    // Dimensione pagina (A3/A4/A5) e scala del pattern (quadretti/righe/crocette).
    var pageSizeRaw: String = PageSize.a4.rawValue
    var patternScale: Double = 1.0

    // LEGACY: i widget flottanti sul foglio sono stati eliminati (tutti
    // gli strumenti vivono nel pannello laterale destro). La relazione e
    // il tipo NoteWidget restano dichiarati solo per compatibilità con lo
    // store già scritto su disco — non rimuoverli senza una migrazione.
    @Relationship(deleteRule: .cascade, originalName: "widgets", inverse: \NoteWidget.note)
    private var widgetsStorage: [NoteWidget]? = []
    var widgets: [NoteWidget] {
        get { widgetsStorage ?? [] }
        set { widgetsStorage = newValue }
    }

    // Campi legacy: usati solo per migrare al volo le note create prima
    // del modello a pagine reali (vedi migrateLegacyContentToPages). La
    // lavagna infinita (isWhiteboard) resta l'unica a disegnare da questi,
    // dato che non ha pagine.
    var drawingData: Data?
    @Attribute(.externalStorage) var pdfBackgroundData: Data?

    // Pagine reali della nota: ognuna con il proprio PKDrawing e un
    // eventuale sfondo PDF (una singola pagina di un PDF importato), in
    // scorrimento continuo verticale — come Notability. Permette di avere
    // pagine scritte a mano prima e dopo un PDF importato, non solo un
    // unico sfondo per l'intera nota. Non usate dalla lavagna infinita.
    @Relationship(deleteRule: .cascade, originalName: "pages", inverse: \NotePage.note)
    private var pagesStorage: [NotePage]? = []
    var pages: [NotePage] {
        get { pagesStorage ?? [] }
        set { pagesStorage = newValue }
    }

    // Strumenti aperti nel pannello laterale destro, come JSON di
    // rawValue. Stanno sulla NOTA e non nella view: il pannello è parte
    // del foglio su cui stai lavorando — la to-do list di Analisi non ha
    // senso mentre apri Economia — e così sopravvive anche alla chiusura
    // e riapertura della nota.
    var sidePanelToolsRaw: String = "[]"

    // Nota creata come "Lavagna infinita" dal menu Nuovo documento: stesso
    // foglio a scorrimento infinito, ma pensata come tela libera (bianca,
    // senza impostazioni di pagina in primo piano) invece che come nota.
    var isWhiteboard: Bool = false

    init(title: String, content: String = "", folder: Folder? = nil) {
        self.id = UUID()
        self.title = title
        self.content = content
        self.createdAt = .now
        self.updatedAt = .now
        self.folder = folder
        self.templateRaw = NoteTemplate.blank.rawValue
        self.pageSizeRaw = PageSize.a4.rawValue
    }
}

enum PageSize: String, CaseIterable, Codable {
    case a3, a4, a5

    var label: String { rawValue.uppercased() }

    // Larghezza di riferimento del foglio in punti (96dpi), l'altezza è comunque infinita/a scorrimento.
    var width: CGFloat {
        switch self {
        case .a3: 1123
        case .a4: 794
        case .a5: 559
        }
    }

    // Altezza di una "pagina virtuale" (rapporto ISO √2), usata per la
    // navigazione avanti/indietro e le miniature nelle impostazioni nota:
    // il foglio resta un unico scorrimento continuo, le pagine sono
    // segmenti calcolati di quello scorrimento, non pagine reali separate.
    var height: CGFloat { width * 1.41421356 }
}

// Unità REALI: le pagine sono in scala 96 dpi (A4 = 794 pt = 210 mm),
// quindi 1 mm = 96/25,4 ≈ 3,78 punti, per qualunque formato. Spessori e
// spaziature restano salvati in punti; i millimetri sono solo il modo
// umano di mostrarli — come sui quaderni e sulle penne vere.
enum RealUnits {
    static let pointsPerMM: CGFloat = 96.0 / 25.4

    static func mm(fromPoints points: CGFloat) -> Double {
        Double(points / pointsPerMM)
    }

    // "0,8 mm", con al massimo un decimale (due sotto il mezzo
    // millimetro, dove il decimale singolo appiattirebbe le differenze).
    static func mmLabel(fromPoints points: CGFloat) -> String {
        let value = mm(fromPoints: points)
        let decimals = value < 0.95 ? 2 : 1
        return value.formatted(.number.precision(.fractionLength(0...decimals))) + " mm"
    }
}

// MARK: - Media

enum NoteMediaKind: String, Codable {
    case image
    case pdf
    // Formula composta dalla penna magica: tecnicamente un'immagine, ma
    // sul foglio deve comportarsi come un tratto di penna — niente
    // cornice né sfondo, che su una formula sembrerebbero un errore.
    case formula
}

// Un'immagine o un PDF posizionato liberamente sul foglio della nota,
// in coordinate del contenuto (non dello schermo). I dati grezzi vengono
// salvati fuori dal database principale (.externalStorage) perché
// possono essere pesanti.
@Model
final class NoteMedia {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 260
    var height: Double = 200
    var kindRaw: String = NoteMediaKind.image.rawValue
    @Attribute(.externalStorage) var data: Data = Data()
    // Sorgente da cui l'immagine è stata generata (il LaTeX di una
    // formula): senza, una formula composta sarebbe pixel e basta, non
    // più correggibile. È ciò che rende la formula "modificabile".
    var sourceText: String?
    var note: Note?

    var kind: NoteMediaKind {
        get { NoteMediaKind(rawValue: kindRaw) ?? .image }
        set { kindRaw = newValue.rawValue }
    }

    init(x: Double, y: Double, width: Double = 260, height: Double = 200, kind: NoteMediaKind, data: Data, sourceText: String? = nil, note: Note? = nil) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.kindRaw = kind.rawValue
        self.data = data
        self.sourceText = sourceText
        self.note = note
    }
}

extension Note {
    var sidePanelTools: [String] {
        get {
            guard let data = sidePanelToolsRaw.data(using: .utf8),
                  let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return list
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let string = String(data: data, encoding: .utf8) else { return }
            sidePanelToolsRaw = string
        }
    }

    var template: NoteTemplate {
        get { NoteTemplate(rawValue: templateRaw) ?? .blank }
        set { templateRaw = newValue.rawValue }
    }

    var pageSize: PageSize {
        get { PageSize(rawValue: pageSizeRaw) ?? .a4 }
        set { pageSizeRaw = newValue.rawValue }
    }

    var textBoxes: [NoteTextBox] {
        get {
            guard let textBoxesData else { return [] }
            return (try? JSONDecoder().decode([NoteTextBox].self, from: textBoxesData)) ?? []
        }
        set {
            textBoxesData = try? JSONEncoder().encode(newValue)
            content = newValue.map(\.text).joined(separator: " ")
        }
    }

    var todoItems: [ChecklistItem] {
        get {
            guard let todoItemsData else { return [] }
            return (try? JSONDecoder().decode([ChecklistItem].self, from: todoItemsData)) ?? []
        }
        set {
            todoItemsData = try? JSONEncoder().encode(newValue)
            updatedAt = .now
        }
    }

    var sortedPages: [NotePage] { pages.sorted { $0.order < $1.order } }

    // Se la nota non ha ancora pagine reali (creata prima di questo
    // modello, o mai aperta da quando è tornato), ne genera dai vecchi
    // campi drawingData/pdfBackgroundData — una pagina per ogni pagina del
    // PDF legacy, o una sola pagina bianca con l'inchiostro esistente se
    // non c'era un PDF. Chiamata da sola all'apertura della nota, così i
    // contenuti già scritti non si perdono.
    // Le nuove pagine vanno agganciate mutando il lato genitore
    // (pages.append) e MAI solo impostando page.note: con SwiftData la
    // mutazione fatta solo sul lato figlio può non notificare
    // l'osservazione di `pages` sul genitore, e la vista non si aggiorna —
    // era il motivo per cui pagine nuove (PDF importati, pagine bianche)
    // non comparivano mai a schermo.
    private func attach(_ page: NotePage, in context: ModelContext) {
        context.insert(page)
        pages.append(page)
    }

    // Estrae la pagina `index` come PDF a sé stante SENZA spostare
    // l'oggetto pagina in un nuovo documento: `PDFDocument().insert(page)`
    // perde le annotazioni (restano legate al documento d'origine), e la
    // scrittura a mano dei PDF esportati dalle app di note È fatta di
    // annotazioni — si importavano le righe/quadretti della pagina ma non
    // la calligrafia. Qui si parte da una copia del documento intero e si
    // eliminano le altre pagine: nulla attraversa i documenti, nulla si perde.
    static func singlePagePDFData(from data: Data, pageIndex: Int) -> Data? {
        guard let copy = PDFDocument(data: data), copy.pageCount > pageIndex else { return nil }
        for other in stride(from: copy.pageCount - 1, through: 0, by: -1) where other != pageIndex {
            copy.removePage(at: other)
        }
        return copy.dataRepresentation()
    }

    @discardableResult
    func migrateLegacyContentToPages(in context: ModelContext) -> [NotePage] {
        guard pages.isEmpty else { return sortedPages }

        if let legacyPDF = pdfBackgroundData, let document = PDFDocument(data: legacyPDF), document.pageCount > 0 {
            var created: [NotePage] = []
            for index in 0..<document.pageCount {
                let page = NotePage(
                    order: index,
                    drawingData: index == 0 ? drawingData : nil,
                    pdfPageData: Note.singlePagePDFData(from: legacyPDF, pageIndex: index)
                )
                attach(page, in: context)
                created.append(page)
            }
            return created
        }

        let page = NotePage(order: 0, drawingData: drawingData)
        attach(page, in: context)
        return [page]
    }

    // Aggiunge una pagina per ciascuna pagina del PDF in coda alle pagine
    // esistenti — così un PDF importato dopo aver già scritto diventa
    // pagine vere in fondo, e si può continuare a scrivere ancora dopo.
    // Restituisce false se `data` non è un PDF valido (es. WeBeep ha
    // restituito una pagina di errore/login invece del file vero): prima
    // veniva ignorato in silenzio e la nota restava vuota senza spiegazioni.
    @discardableResult
    func appendPages(fromPDF data: Data, in context: ModelContext) -> Bool {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { return false }
        migrateLegacyContentToPages(in: context)
        var nextOrder = (sortedPages.last?.order ?? -1) + 1
        for index in 0..<document.pageCount {
            // autoreleasepool: l'estrazione di ogni pagina apre una copia
            // dell'INTERO documento. Senza svuotare il pool a ogni giro,
            // su una dispensa da 60+ pagine le copie si accumulavano tutte
            // insieme e l'app moriva di memoria già durante l'import.
            autoreleasepool {
                let page = NotePage(order: nextOrder, pdfPageData: Note.singlePagePDFData(from: data, pageIndex: index))
                attach(page, in: context)
                nextOrder += 1
            }
        }
        return true
    }

    func appendBlankPage(in context: ModelContext) {
        migrateLegacyContentToPages(in: context)
        let page = NotePage(order: (sortedPages.last?.order ?? -1) + 1)
        attach(page, in: context)
    }

    // Scorrimento continuo alla Notability: sotto l'ultima pagina con del
    // contenuto ce n'è sempre una vuota pronta, così non si sbatte mai
    // contro un "muro" e c'è sempre spazio dove continuare a scrivere.
    func ensureTrailingBlankPage(in context: ModelContext) {
        migrateLegacyContentToPages(in: context)
        guard let last = sortedPages.last else {
            appendBlankPage(in: context)
            return
        }
        let lastHasInk: Bool = {
            guard let data = last.drawingData, let drawing = try? PKDrawing(data: data) else { return false }
            return !drawing.strokes.isEmpty
        }()
        if last.pdfPageData != nil || lastHasInk {
            appendBlankPage(in: context)
        }
    }

    // Inserisce una pagina bianca in una posizione precisa (es. prima o
    // dopo una pagina PDF importata), spostando avanti l'ordine di tutte
    // le pagine successive — non solo in fondo come appendBlankPage.
    func insertBlankPage(at index: Int, in context: ModelContext) {
        migrateLegacyContentToPages(in: context)
        let clampedIndex = max(0, min(index, pages.count))
        for page in sortedPages where page.order >= clampedIndex {
            page.order += 1
        }
        let page = NotePage(order: clampedIndex)
        attach(page, in: context)
    }
}

// Non più usato dall'editor: si è tornati a un unico PKDrawing continuo
// per nota (vedi Note.drawingData). Il tipo resta dichiarato solo per
// compatibilità con lo store già scritto su disco durante la breve
// sperimentazione con pagine reali indipendenti — non rimuoverlo senza
// una migrazione dello schema SwiftData.
@Model
final class NotePage {
    var order: Int = 0
    var drawingData: Data?
    @Attribute(.externalStorage) var pdfPageData: Data?
    var note: Note?

    init(order: Int, drawingData: Data? = nil, pdfPageData: Data? = nil, note: Note? = nil) {
        self.order = order
        self.drawingData = drawingData
        self.pdfPageData = pdfPageData
        self.note = note
    }
}

struct ChecklistItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var isDone: Bool = false
}

// MARK: - Widget

enum NoteWidgetKind: String, Codable {
    case graph, todo, pomodoro, wolfram
}

// Un widget interattivo (grafico, to-do, pomodoro, wolfram) posizionato
// liberamente sul foglio, in coordinate del contenuto. Lo stato specifico
// del widget (espressione del grafico, elementi to-do, ecc.) è salvato
// come JSON in `dataJSON` per restare flessibile senza nuove tabelle.
@Model
final class NoteWidget {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 260
    var height: Double = 200
    var kindRaw: String = NoteWidgetKind.todo.rawValue
    var dataJSON: String = "{}"
    var note: Note?

    var kind: NoteWidgetKind {
        get { NoteWidgetKind(rawValue: kindRaw) ?? .todo }
        set { kindRaw = newValue.rawValue }
    }

    init(x: Double, y: Double, width: Double, height: Double, kind: NoteWidgetKind, note: Note? = nil) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.kindRaw = kind.rawValue
        self.note = note
    }

    func decode<T: Decodable>(_ type: T.Type, default defaultValue: T) -> T {
        guard let data = dataJSON.data(using: .utf8) else { return defaultValue }
        return (try? JSONDecoder().decode(T.self, from: data)) ?? defaultValue
    }

    func encode(_ value: some Encodable) {
        guard let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) else { return }
        dataJSON = string
    }
}

struct GraphWidgetState: Codable {
    var expression: String = "x^2 - 9"
}

struct TodoWidgetState: Codable {
    var items: [ChecklistItem] = []
}

struct PomodoroWidgetState: Codable {
    var durationMinutes: Int = 25
}

struct WolframWidgetState: Codable {
    var expression: String = ""
    var result: String?
    var imageURLs: [URL] = []
}
