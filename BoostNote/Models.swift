import Foundation
import SwiftData
import SwiftUI
import PDFKit

// MARK: - Cartella
// Rappresenta una cartella nell'organizzazione delle note.
// Supporta cartelle annidate tramite la relazione parent/children.
@Model
final class Folder {
    var name: String
    var createdAt: Date
    var parent: Folder?

    // Colore dell'icona cartella, salvato come rawValue di FolderColor.
    // Il default qui serve alla migrazione automatica di SwiftData.
    var colorRaw: String = FolderColor.blue.rawValue

    @Relationship(deleteRule: .cascade, inverse: \Folder.parent)
    var children: [Folder] = []

    @Relationship(deleteRule: .cascade, inverse: \Note.folder)
    var notes: [Note] = []

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

    var color: Color {
        switch self {
        case .gray: DesignColor.textSecondary
        case .blue: DesignColor.brandPrimary
        case .red: DesignColor.danger
        case .green: DesignColor.success
        case .orange: DesignColor.toolWolfram
        case .purple: DesignColor.toolLatex
        case .teal: DesignColor.toolExplain
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
    var title: String
    // Testo ricavato dalle caselle di testo, usato solo per l'anteprima
    // nella lista note e per la ricerca. Non è editabile direttamente.
    var content: String
    var createdAt: Date
    var updatedAt: Date
    var folder: Folder?

    // Caselle di testo posizionate sul foglio, serializzate come JSON.
    var textBoxesData: Data?

    // Modello del foglio (quadretti, righe, crocette, bianco), salvato come rawValue.
    // Il default qui (non solo nell'init) serve alla migrazione automatica di SwiftData.
    var templateRaw: String = NoteTemplate.blank.rawValue

    // Immagini e PDF inseriti sul foglio.
    @Relationship(deleteRule: .cascade, inverse: \NoteMedia.note)
    var media: [NoteMedia] = []

    // Dimensione pagina (A3/A4/A5) e scala del pattern (quadretti/righe/crocette).
    var pageSizeRaw: String = PageSize.a4.rawValue
    var patternScale: Double = 1.0

    // Widget interattivi inseriti sul foglio (grafici, to-do, pomodoro, wolfram).
    @Relationship(deleteRule: .cascade, inverse: \NoteWidget.note)
    var widgets: [NoteWidget] = []

    // Tratti PencilKit dell'intero foglio (lavagna o nota): un unico
    // scorrimento continuo, non pagine separate — vedi InfiniteCanvasView.
    var drawingData: Data?
    // Se la nota è nata da un PDF importato "come foglio", questo è lo
    // sfondo (multi-pagina) su cui si annota, mostrato in scorrimento
    // verticale continuo al posto del pattern quadretti/righe/crocette.
    @Attribute(.externalStorage) var pdfBackgroundData: Data?

    // NotePage non è più usato dall'editor (si è tornati a un unico
    // PKDrawing continuo): la relazione resta dichiarata solo per
    // compatibilità con lo store già scritto su disco durante la breve
    // sperimentazione con pagine reali indipendenti.
    @Relationship(deleteRule: .cascade, inverse: \NotePage.note)
    var pages: [NotePage] = []

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

// MARK: - Media

enum NoteMediaKind: String, Codable {
    case image
    case pdf
}

// Un'immagine o un PDF posizionato liberamente sul foglio della nota,
// in coordinate del contenuto (non dello schermo). I dati grezzi vengono
// salvati fuori dal database principale (.externalStorage) perché
// possono essere pesanti.
@Model
final class NoteMedia {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var kindRaw: String = NoteMediaKind.image.rawValue
    @Attribute(.externalStorage) var data: Data = Data()
    var note: Note?

    var kind: NoteMediaKind {
        get { NoteMediaKind(rawValue: kindRaw) ?? .image }
        set { kindRaw = newValue.rawValue }
    }

    init(x: Double, y: Double, width: Double = 260, height: Double = 200, kind: NoteMediaKind, data: Data, note: Note? = nil) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.kindRaw = kind.rawValue
        self.data = data
        self.note = note
    }
}

extension Note {
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

    // Aggiunge le pagine di un PDF importato in coda a quelle già presenti
    // come sfondo del foglio (o le imposta se non c'era ancora uno
    // sfondo) — un secondo import si accoda in fondo, non sostituisce.
    func appendPDFPages(from data: Data) {
        guard let newDocument = PDFDocument(data: data), newDocument.pageCount > 0 else { return }
        guard let existingData = pdfBackgroundData, let existingDocument = PDFDocument(data: existingData) else {
            pdfBackgroundData = data
            return
        }
        for index in 0..<newDocument.pageCount {
            guard let page = newDocument.page(at: index) else { continue }
            existingDocument.insert(page, at: existingDocument.pageCount)
        }
        pdfBackgroundData = existingDocument.dataRepresentation()
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
    var x: Double
    var y: Double
    var width: Double
    var height: Double
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
