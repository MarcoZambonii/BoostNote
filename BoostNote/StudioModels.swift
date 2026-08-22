import Foundation
import SwiftData
import SwiftUI

// MARK: - Cartella di studio
// Cartelle vere e annidabili per organizzare gli studi, con la stessa
// forma di `Folder` per le note: così l'albero nella barra laterale si
// comporta allo stesso modo nei due ambienti e non c'è niente di nuovo
// da imparare passando da Note a Studio.
@Model
final class StudyFolder {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date.now
    var colorRaw: String = FolderColor.purple.rawValue
    var parent: StudyFolder?

    // To-many opzionali con wrapper: requisito CloudKit, vedi Folder.
    @Relationship(deleteRule: .cascade, originalName: "children", inverse: \StudyFolder.parent)
    private var childrenStorage: [StudyFolder]? = []
    var children: [StudyFolder] {
        get { childrenStorage ?? [] }
        set { childrenStorage = newValue }
    }

    // Eliminando la cartella gli studi NON si perdono: tornano alla
    // radice (regola .nullify), perché uno studio è lavoro costoso da
    // rigenerare e non deve sparire per un riordino.
    @Relationship(deleteRule: .nullify, originalName: "studies", inverse: \Study.folder)
    private var studiesStorage: [Study]? = []
    var studies: [Study] {
        get { studiesStorage ?? [] }
        set { studiesStorage = newValue }
    }

    // Il vault del corso (cartella = corso, deciso 2026-08-15): i
    // documenti del vault muoiono con la cartella — a differenza degli
    // studi, il loro contenuto si può sempre rileggere dalle fonti.
    @Relationship(deleteRule: .cascade, originalName: "vaultDocuments", inverse: \VaultDocument.folder)
    private var vaultDocumentsStorage: [VaultDocument]? = []
    var vaultDocuments: [VaultDocument] {
        get { vaultDocumentsStorage ?? [] }
        set { vaultDocumentsStorage = newValue }
    }

    init(name: String, parent: StudyFolder? = nil, color: FolderColor = .purple) {
        self.id = UUID()
        self.name = name
        self.createdAt = .now
        self.parent = parent
        self.colorRaw = color.rawValue
    }

    var folderColor: FolderColor {
        get { FolderColor(rawValue: colorRaw) ?? .purple }
        set { colorRaw = newValue.rawValue }
    }

    var sortedChildren: [StudyFolder] { children.sorted { $0.name < $1.name } }
    var sortedStudies: [Study] { studies.sorted { $0.updatedAt > $1.updatedAt } }
}

// MARK: - Studio
// Uno "studio" è un percorso di ripasso generato dai materiali scelti
// dall'utente (note, file WeBeep, PDF caricati): contiene i moduli
// generati (riassunto, esercizi, ...) e i tentativi fatti sugli esercizi,
// da cui il pannello "Analisi dei progressi" ricava i grafici.
@Model
final class Study {
    var id: UUID = UUID()
    var name: String = ""
    // Materia libera usata per raggruppare gli studi nella sidebar
    // (vuota = "Senza materia"). Testo libero e non un'entità dedicata:
    // stessa scelta fatta per i titoli delle note, si può promuovere a
    // modello se un giorno servirà colore/ordinamento per materia.
    var subject: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    // Cartella che lo contiene; nil = radice dell'albero.
    var folder: StudyFolder?

    // Materiali sorgente serializzati come JSON ([StudySourceMaterial]):
    // le note sono riferite per UUID (stesso approccio del drag-and-drop
    // in SidebarView), i file WeBeep/PDF solo come metadati — il testo
    // vero viene riletto al momento della generazione.
    var sourcesData: Data?

    // Materiali persistiti con il loro testo già estratto. Sostituiscono
    // `sourcesData` (che resta solo per gli studi creati prima): lì
    // c'erano i soli metadati, e il testo veniva riletto ogni volta dalla
    // nota — impossibile per PDF e file WeBeep, e comunque uno spreco
    // visto che l'OCR della scrittura a mano non è istantaneo.
    @Relationship(deleteRule: .cascade, originalName: "materials", inverse: \StudyMaterial.study)
    private var materialsStorage: [StudyMaterial]? = []
    var materials: [StudyMaterial] {
        get { materialsStorage ?? [] }
        set { materialsStorage = newValue }
    }

    @Relationship(deleteRule: .cascade, originalName: "modules", inverse: \StudyModule.study)
    private var modulesStorage: [StudyModule]? = []
    var modules: [StudyModule] {
        get { modulesStorage ?? [] }
        set { modulesStorage = newValue }
    }

    @Relationship(deleteRule: .cascade, originalName: "attempts", inverse: \ExerciseAttempt.study)
    private var attemptsStorage: [ExerciseAttempt]? = []
    var attempts: [ExerciseAttempt] {
        get { attemptsStorage ?? [] }
        set { attemptsStorage = newValue }
    }

    init(name: String, subject: String = "") {
        self.id = UUID()
        self.name = name
        self.subject = subject
        self.createdAt = .now
        self.updatedAt = .now
    }
}

extension Study {
    var sources: [StudySourceMaterial] {
        get {
            guard let sourcesData else { return [] }
            return (try? JSONDecoder().decode([StudySourceMaterial].self, from: sourcesData)) ?? []
        }
        set {
            sourcesData = try? JSONEncoder().encode(newValue)
        }
    }

    var sortedModules: [StudyModule] { modules.sorted { $0.order < $1.order } }

    // Gruppo mostrato nella sidebar: la materia se impostata.
    var subjectOrPlaceholder: String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Senza materia" : trimmed
    }
}

// Materiale di uno studio, con il testo già estratto on-device.
// `extractedTextData` e `pdfData` vanno in externalStorage perché il
// testo di una dispensa lunga e il PDF originale non devono appesantire
// il database principale.
@Model
final class StudyMaterial {
    var id: UUID = UUID()
    var title: String = ""
    var subtitle: String?
    var kindRaw: String = StudySourceKind.note.rawValue
    var isExamPaper: Bool = false
    // Nota di origine, se il materiale viene dall'app.
    var noteID: UUID?
    @Attribute(.externalStorage) var pdfData: Data?
    @Attribute(.externalStorage) var extractedTextData: Data?
    // Stato dell'estrazione, per mostrare l'avanzamento e i fallimenti
    // invece di lasciare il materiale silenziosamente vuoto.
    var extractionError: String?
    var study: Study?

    var kind: StudySourceKind {
        get { StudySourceKind(rawValue: kindRaw) ?? .file }
        set { kindRaw = newValue.rawValue }
    }

    var extractedText: String {
        get {
            guard let extractedTextData else { return "" }
            return String(data: extractedTextData, encoding: .utf8) ?? ""
        }
        set { extractedTextData = newValue.data(using: .utf8) }
    }

    var hasText: Bool { !extractedText.trimmingCharacters(in: .whitespaces).isEmpty }

    init(title: String, subtitle: String? = nil, kind: StudySourceKind, isExamPaper: Bool = false, noteID: UUID? = nil, pdfData: Data? = nil, study: Study? = nil) {
        self.id = UUID()
        self.title = title
        self.subtitle = subtitle
        self.kindRaw = kind.rawValue
        self.isExamPaper = isExamPaper
        self.noteID = noteID
        self.pdfData = pdfData
        self.study = study
    }
}

// MARK: - Materiali sorgente

enum StudySourceKind: String, Codable {
    case note        // una nota dell'app, riferita per UUID
    case webeep      // un file recuperato da WeBeep (slide, dispense, temi d'esame)
    case file        // un PDF caricato a mano dall'utente
    case vault       // un documento del Vault del corso: testo GIÀ letto

    var systemImage: String {
        switch self {
        case .note: "note.text"
        case .webeep: "building.columns.fill"
        case .file: "doc.richtext"
        case .vault: "archivebox"
        }
    }
}

struct StudySourceMaterial: Codable, Identifiable, Hashable {
    var id = UUID()
    var kindRaw: String
    var title: String
    // Contesto extra: nome del corso WeBeep o della cartella della nota.
    var subtitle: String?
    var noteID: UUID?
    // Un tema d'esame dà la FORMA agli esercizi da risolvere (tipologia e
    // struttura delle richieste, da cui inventarne di nuovi); tutto il
    // resto alimenta la teoria — riassunti ed esercizi teorici.
    var isExamPaper: Bool = false
    // Riferimento al file WeBeep, tenuto da parte per poterlo scaricare
    // al momento della generazione invece che alla selezione.
    var webeepFileURL: String?
    var webeepMimeType: String?
    // Riferimento al documento del Vault (kind == .vault). Opzionale per
    // la TRAPPOLA Codable nota: i JSON già salvati non hanno la chiave.
    var vaultDocumentID: UUID?

    var kind: StudySourceKind {
        get { StudySourceKind(rawValue: kindRaw) ?? .file }
        set { kindRaw = newValue.rawValue }
    }

    var webeepFile: WebeepFile? {
        guard let webeepFileURL else { return nil }
        return WebeepFile(filename: title, fileurl: webeepFileURL, mimetype: webeepMimeType, filepath: nil)
    }

    init(kind: StudySourceKind, title: String, subtitle: String? = nil, noteID: UUID? = nil, isExamPaper: Bool = false, webeepFileURL: String? = nil, webeepMimeType: String? = nil, vaultDocumentID: UUID? = nil) {
        self.kindRaw = kind.rawValue
        self.title = title
        self.subtitle = subtitle
        self.noteID = noteID
        self.isExamPaper = isExamPaper
        self.webeepFileURL = webeepFileURL
        self.webeepMimeType = webeepMimeType
        self.vaultDocumentID = vaultDocumentID
    }
}

// MARK: - Moduli
// Il tipo di modulo è un rawValue String (non un enum SwiftData): un tipo
// nuovo si aggiunge dichiarando un caso qui e il relativo payload Codable,
// senza migrazioni di schema — lo stesso pattern di NoteWidgetKind.
enum StudyModuleKind: String, CaseIterable, Codable {
    case summary, exercises, reviewPoints, flashcards

    var label: String {
        switch self {
        case .summary: "Riassunto"
        case .exercises: "Esercizi"
        // Il valore salvato resta `reviewPoints`: cambiarlo renderebbe
        // illeggibili gli studi già creati. Cambia solo il nome mostrato,
        // che ora dice cosa sono diventati — la metà concettuale che gli
        // esercizi non fanno più.
        case .reviewPoints: "Esercizi teorici"
        case .flashcards: "Flashcard"
        }
    }

    // Descrizione mostrata nelle card del flusso "Crea nuovo studio".
    var subtitle: String {
        switch self {
        case .summary: "Sintesi dei materiali, sezione per sezione"
        case .exercises: "Tracce da risolvere, sui temi d'esame"
        case .reviewPoints: "Domande di ragionamento sulla teoria"
        case .flashcards: "Carte domanda/risposta da ripassare"
        }
    }

    var systemImage: String {
        switch self {
        case .summary: "text.alignleft"
        case .exercises: "pencil.and.list.clipboard"
        case .reviewPoints: "brain.head.profile"
        case .flashcards: "rectangle.on.rectangle"
        }
    }

    var color: Color {
        switch self {
        case .summary: DesignColor.brandPrimary
        case .exercises: DesignColor.toolWolfram
        case .reviewPoints: DesignColor.toolExplain
        case .flashcards: DesignColor.toolLatex
        }
    }
}

enum StudyModuleStatus: String, Codable {
    case pending, generating, ready, failed
}

@Model
final class StudyModule {
    var id: UUID = UUID()
    var kindRaw: String = StudyModuleKind.summary.rawValue
    var statusRaw: String = StudyModuleStatus.pending.rawValue
    var order: Int = 0
    // Contenuto generato, come JSON del payload Codable del tipo di modulo
    // (SummaryContent, ExerciseSetContent, ...). Flessibile come
    // NoteWidget.dataJSON: nessuna tabella nuova per un tipo nuovo.
    var contentJSON: String = "{}"
    // Opzioni scelte alla creazione (difficoltà, categorie di esercizi).
    var optionsJSON: String = "{}"
    var createdAt: Date = Date.now
    var study: Study?

    // Da dove viene il contenuto: "ai" (provider reale) o "mock"
    // (contenuto d'esempio). Con l'eventuale motivo del ripiego sul mock,
    // mostrato in UI: prima il fallback era silenzioso e non si capiva
    // perché la generazione reale non fosse partita.
    var generatedByRaw: String = "mock"
    var generationError: String?

    // Quanti contenuti la verifica indipendente ha scartato in questa
    // generazione: si mostra all'utente invece di sparire in silenzio —
    // è la prova che il controllo ha davvero lavorato.
    var discardedCount: Int = 0

    // Id dei contenuti segnalati come sbagliati dall'utente (JSON di
    // stringhe UUID): la rete di sicurezza finale, quella umana.
    var reportedIDsJSON: String = "[]"

    var kind: StudyModuleKind? {
        StudyModuleKind(rawValue: kindRaw)
    }

    // Segnalazioni: id del contenuto -> motivo indicato dall'utente.
    // Il campo era nato come semplice elenco di id; si decodifica ancora
    // anche quel formato per non perdere le segnalazioni già salvate.
    var reports: [String: String] {
        get {
            guard let data = reportedIDsJSON.data(using: .utf8) else { return [:] }
            if let dict = try? JSONDecoder().decode([String: String].self, from: data) { return dict }
            if let list = try? JSONDecoder().decode([String].self, from: data) {
                return Dictionary(uniqueKeysWithValues: list.map { ($0, "") })
            }
            return [:]
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let string = String(data: data, encoding: .utf8) else { return }
            reportedIDsJSON = string
        }
    }

    var reportedIDs: Set<String> { Set(reports.keys) }

    func report(_ id: UUID, reason: String) {
        var current = reports
        current[id.uuidString] = reason
        reports = current
    }

    func clearReport(_ id: UUID) {
        var current = reports
        current.removeValue(forKey: id.uuidString)
        reports = current
    }

    func isReported(_ id: UUID) -> Bool {
        reports[id.uuidString] != nil
    }

    func reportReason(_ id: UUID) -> String? {
        let reason = reports[id.uuidString]
        return (reason?.isEmpty ?? true) ? nil : reason
    }

    var status: StudyModuleStatus {
        get { StudyModuleStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    init(kind: StudyModuleKind, order: Int, options: StudyModuleOptions = StudyModuleOptions(), study: Study? = nil) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.order = order
        self.study = study
        self.createdAt = .now
        encodeOptions(options)
    }

    func decodeContent<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = contentJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func encodeContent(_ value: some Encodable) {
        guard let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) else { return }
        contentJSON = string
    }

    var options: StudyModuleOptions {
        guard let data = optionsJSON.data(using: .utf8) else { return StudyModuleOptions() }
        return (try? JSONDecoder().decode(StudyModuleOptions.self, from: data)) ?? StudyModuleOptions()
    }

    func encodeOptions(_ value: StudyModuleOptions) {
        guard let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) else { return }
        optionsJSON = string
    }
}

// Opzioni di generazione comuni a tutti i moduli (i campi non pertinenti
// per un tipo vengono semplicemente ignorati): un solo struct evita un
// payload di opzioni per tipo finché le opzioni restano poche.
struct StudyModuleOptions: Codable {
    // nil = difficoltà mista (un po' di tutto).
    var difficultyRaw: String?
    // Non più usati: gli esercizi sono tutti da risolvere e la parte
    // concettuale è passata al modulo "Esercizi teorici". Restano perché
    // le opzioni GIÀ SALVATE contengono queste chiavi, e la sintesi di
    // Codable non perdona un campo che sparisce dal tipo ma resta nel
    // JSON... nel verso opposto: toglierli è sicuro in lettura, ma li
    // legge ancora `exerciseCount` per capire quanti esercizi voleva chi
    // ha salvato le opzioni prima del cambio.
    var includeTheoretical: Bool = true
    var includePractical: Bool = true
    // Doppio passaggio: una seconda chiamata rifà gli esercizi da zero e
    // quelli in disaccordo vengono scartati. Costa una chiamata in più per
    // set, quindi è disattivabile per chi ha poca quota free tier.
    var verifyExercises: Bool = true

    // Quanti esercizi PER ARGOMENTO. Gli argomenti li individua il
    // modello leggendo i materiali: questo numero controlla la
    // profondità, non l'ampiezza — la copertura è completa per
    // costruzione. OPZIONALI di proposito: la sintesi di Codable non
    // applica i default quando la chiave manca, lancia keyNotFound, e le
    // opzioni già salvate non hanno queste chiavi.
    var theoreticalCountValue: Int?
    var practicalCountValue: Int?

    // Argomenti scelti dall'indice del Vault. nil o vuoto = tutti quelli
    // dei materiali scelti (comportamento di sempre). Servono a due cose
    // insieme: restringere il campo per avere PROFONDITÀ invece di un
    // esercizio a testa su trenta argomenti, e dare al modello un
    // VOCABOLARIO CONTROLLATO per il campo "topic" — senza, ogni
    // generazione se lo inventa con parole sue ("dualità in PL" vs
    // "problema duale") e l'analisi dei progressi, che raggruppa per
    // quella stringa, frantuma le statistiche dello stesso argomento.
    // Opzionale per la stessa trappola Codable di qui sopra.
    var selectedTopicsValue: [String]?

    var selectedTopics: [String] {
        get { selectedTopicsValue ?? [] }
        set { selectedTopicsValue = newValue.isEmpty ? nil : newValue }
    }

    var theoreticalCount: Int {
        get { theoreticalCountValue ?? 1 }
        set { theoreticalCountValue = newValue }
    }

    var practicalCount: Int {
        get { practicalCountValue ?? 1 }
        set { practicalCountValue = newValue }
    }

    // Quanti esercizi per argomento, ORA CHE SONO TUTTI PRATICI. Erano
    // due numeri perché il modulo mescolava le due nature; la parte
    // concettuale è passata ai punti di ripasso e il numero è tornato
    // uno. I due vecchi campi restano solo per le opzioni GIÀ SALVATE:
    // se il nuovo manca, il totale che l'utente aveva chiesto allora
    // resta quello giusto adesso.
    var exerciseCountValue: Int?

    var exerciseCount: Int {
        get { exerciseCountValue ?? max(1, theoreticalCount + practicalCount) }
        set { exerciseCountValue = newValue }
    }

    var difficulty: ExerciseDifficulty? {
        get { difficultyRaw.flatMap(ExerciseDifficulty.init(rawValue:)) }
        set { difficultyRaw = newValue?.rawValue }
    }
}

// MARK: - Esercizi

enum ExerciseDifficulty: String, Codable, CaseIterable {
    case base, medio, avanzato

    var label: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .base: DesignColor.success
        case .medio: DesignColor.toolSearch
        case .avanzato: DesignColor.danger
        }
    }
}

enum ExerciseCategory: String, Codable, CaseIterable {
    case theoretical, practical

    // Gli stessi nomi dei due moduli (vedi StudyModuleKind.label): il
    // tentativo registrato nell'analisi deve chiamarsi come la scheda da
    // cui arriva, o l'utente deve indovinare la corrispondenza.
    var label: String {
        switch self {
        case .theoretical: "Esercizi teorici"
        case .practical: "Esercizi"
        }
    }

    var explanation: String {
        switch self {
        case .theoretical: "Domande di ragionamento su note e dispense"
        case .practical: "Tracce da risolvere, sui temi d'esame"
        }
    }

    var systemImage: String {
        switch self {
        case .theoretical: "book"
        case .practical: "function"
        }
    }
}

// MARK: - Payload dei moduli

struct SummaryContent: Codable {
    var sections: [SummarySection] = []
}

struct SummarySection: Codable, Identifiable {
    var id = UUID()
    var title: String
    var body: String
    // Citazione verbatim dal materiale che sostiene questa sezione, con
    // l'esito del controllo di esistenza (vedi SourceCitation).
    var quote: SourceCitation?
}

// Citazione a supporto di un contenuto generato. `text` è ciò che il
// modello dichiara di aver letto nei materiali; `verified` è il risultato
// di un confronto PROGRAMMATICO con il testo sorgente, non un'altra
// affermazione del modello: se la citazione non si trova, il contenuto è
// almeno in parte inventato e va mostrato con riserva.
struct SourceCitation: Codable {
    var text: String
    var sourceTitle: String?
    var verified: Bool = false
}

struct ExerciseSetContent: Codable {
    var exercises: [StudyExercise] = []
}

struct StudyExercise: Codable, Identifiable {
    var id = UUID()
    var categoryRaw: String
    var difficultyRaw: String
    // Argomento (usato per la copertura argomenti nei progressi).
    var topic: String
    var prompt: String
    // Soluzione guidata: passi mostrati uno alla volta.
    var steps: [String] = []
    var answer: String
    // Da quale materiale viene (titolo della nota o del tema d'esame).
    var sourceTitle: String?
    var quote: SourceCitation?
    // Espressione interrogabile da Wolfram il cui risultato deve
    // coincidere con la risposta: permette una verifica FUORI dal modello
    // (vedi il player, che la esegue su richiesta).
    var checkExpression: String?
    // ATTENZIONE — questi campi sono OPZIONALI di proposito, e i nuovi
    // vanno aggiunti così. La sintesi automatica di Codable NON usa il
    // valore di default quando la chiave manca: lancia un errore. Un
    // campo non opzionale aggiunto qui rende quindi illeggibile TUTTO il
    // contenuto generato in precedenza, che sparisce dall'interfaccia
    // senza un messaggio ("0 esercizi"). Con l'opzionale il vecchio JSON
    // continua a decodificarsi e il default arriva dalle proprietà
    // calcolate qui sotto.
    var verificationRaw: String?
    var originRaw: String?
    // Figura TikZ della traccia (grafi, funzioni, catene di Markov…):
    // il sorgente scritto dal modello e, una volta compilato con
    // TikZJax, l'SVG risultante. La compilazione avviene alla prima
    // visualizzazione e il risultato si persiste qui: mai due volte.
    // figureSVG vuoto (non nil) = compilazione fallita, non ritentare.
    var figureTikZ: String?
    var figureSVG: String?
    // "Qui una figura ci voleva, e non c'è." Lo dice o il modello stesso
    // (ha dichiarato figuraServe: true e poi non l'ha scritta — una
    // contraddizione sua, non una nostra interpretazione) oppure il
    // controllo strutturale sulla traccia. Non blocca niente: serve a
    // non far sembrare una mancanza una scelta, ed è l'innesco naturale
    // per una futura generazione mirata delle figure mancanti.
    var figureExpected: Bool?

    var category: ExerciseCategory { ExerciseCategory(rawValue: categoryRaw) ?? .theoretical }
    var difficulty: ExerciseDifficulty { ExerciseDifficulty(rawValue: difficultyRaw) ?? .base }
    var verification: ExerciseVerification { ExerciseVerification(rawValue: verificationRaw ?? "") ?? .notChecked }
    var origin: ExerciseOrigin { ExerciseOrigin(rawValue: originRaw ?? "") ?? .invented }

    // Etichetta di provenienza mostrata accanto all'esercizio.
    var originLabel: String {
        switch origin {
        case .invented: "Nuovo"
        case .fromMaterials:
            if let sourceTitle, !sourceTitle.isEmpty { "Nei materiali: \(sourceTitle)" } else { "Nei materiali" }
        }
    }
}

// Da dove viene la traccia. Un esercizio "nuovo" è stato scritto
// ispirandosi ai materiali ma con dati propri; uno "dai materiali" è già
// presente lì come tale. Distinguerli conta: sul primo non puoi sbirciare
// la soluzione, sul secondo sì.
enum ExerciseOrigin: String, Codable {
    case invented, fromMaterials

    var systemImage: String {
        switch self {
        case .invented: "sparkles"
        case .fromMaterials: "doc.text.magnifyingglass"
        }
    }

    var color: Color {
        switch self {
        case .invented: DesignColor.toolLatex
        case .fromMaterials: DesignColor.textSecondary
        }
    }
}

// Esito della verifica indipendente di un esercizio. `rejected` non viene
// mai mostrato all'utente (gli esercizi bocciati si scartano): resta come
// valore per completezza e per eventuale debug.
enum ExerciseVerification: String, Codable {
    case notChecked, agreed, rejected

    var label: String? {
        switch self {
        case .notChecked: nil
        case .agreed: "Risolto due volte, stesso risultato"
        case .rejected: "Scartato dalla verifica"
        }
    }
}

struct ReviewPointsContent: Codable {
    var points: [ReviewPoint] = []
}

struct ReviewPoint: Codable, Identifiable {
    var id = UUID()
    // Il concetto da ricordare e la domanda con cui autoverificarsi.
    var statement: String
    var question: String
    var answer: String
    var quote: SourceCitation?
    // Argomento, stessa stringa canonica degli esercizi da risolvere: è
    // quella che fa incontrare teoria e pratica nella stessa riga
    // dell'analisi invece di tenerle in due mondi separati. OPZIONALE per
    // la trappola Codable descritta su StudyExercise: i payload già
    // generati non hanno questa chiave.
    var topic: String?
}

struct FlashcardsContent: Codable {
    var cards: [Flashcard] = []
}

struct Flashcard: Codable, Identifiable {
    var id = UUID()
    var front: String
    var back: String
    var quote: SourceCitation?
}

// MARK: - Tentativi (analisi dei progressi)
// Un record per ogni esercizio autovalutato nel player: è la sorgente
// unica dei grafici in "Analisi dei progressi". Denormalizza argomento,
// difficoltà e categoria così i grafici non devono rileggere i payload
// JSON dei moduli (che potrebbero anche essere stati rigenerati).
@Model
final class ExerciseAttempt {
    var date: Date = Date.now
    var isCorrect: Bool = false
    var durationSeconds: Double = 0
    var topic: String = ""
    var difficultyRaw: String = ExerciseDifficulty.base.rawValue
    var categoryRaw: String = ExerciseCategory.theoretical.rawValue
    var study: Study?

    // nil = tentativo su un esercizio teorico, che una difficoltà non ce
    // l'ha. Diverso da "base": non è facile, è un'altra cosa.
    var difficulty: ExerciseDifficulty? { ExerciseDifficulty(rawValue: difficultyRaw) }
    var category: ExerciseCategory { ExerciseCategory(rawValue: categoryRaw) ?? .theoretical }

    // `difficulty` è OPZIONALE perché gli esercizi teorici non ne hanno
    // una: inventarne una per farceli stare significherebbe sporcare
    // l'accuratezza per difficoltà con dati finti. Chi non ce l'ha salva
    // stringa vuota, e i grafici per difficoltà lo escludono.
    init(date: Date = .now, isCorrect: Bool, durationSeconds: Double, topic: String, difficulty: ExerciseDifficulty?, category: ExerciseCategory, study: Study? = nil) {
        self.date = date
        self.isCorrect = isCorrect
        self.durationSeconds = durationSeconds
        self.topic = topic
        self.difficultyRaw = difficulty?.rawValue ?? ""
        self.categoryRaw = category.rawValue
        self.study = study
    }
}
