import Foundation
import Observation
import SwiftData

// I DTO che sono "un array dentro un oggetto" dichiarano qui quale sia
// quella chiave, così la decodifica può rimpacchettare una risposta
// arrivata con un contenitore diverso. Sta a livello di file perché in
// Swift un protocollo non si può annidare dentro un tipo.
private protocol ArrayWrapped { static var arrayKey: String { get } }

// Testo di avanzamento vivo per la card di un modulo in generazione
// ("Provo gemini-flash-latest (3/5)…"): prima l'attesa era un
// "Generazione in corso…" identico al secondo 2 e al minuto 3.
// Volutamente FUORI da SwiftData: è stato transitorio, a generazione
// finita non deve restarne traccia.
@MainActor
@Observable
final class GenerationProgress {
    static let shared = GenerationProgress()
    var text: [UUID: String] = [:]
}

// Generazione dei contenuti dei moduli di uno studio, via AIService.
//
// Non esiste più una generazione "di esempio" di ripiego: se la chiamata
// non riesce il modulo resta FALLITO con il motivo, e l'utente può
// riprovare. Un riassunto finto sembra un riassunto vero e nasconde il
// problema da sistemare (chiave mancante, quota esaurita, materiali
// senza testo estraibile).
enum StudioGenerationService {

    // Testo effettivo di un materiale sorgente, risolto prima della
    // generazione: il servizio non tocca SwiftData, riceve già i testi.
    struct ResolvedSource {
        var title: String
        var text: String
        var isExamPaper: Bool
    }

    // Risolve i materiali di uno studio nei rispettivi testi: le note per
    // UUID (testo delle caselle di testo), i file WeBeep/PDF solo con il
    // titolo — il mock non estrae testo dai PDF (lo farà la pipeline vera
    // con PDFKit, il cui testo è già disponibile via PDFDocument.string).
    // I materiali persistiti portano già il testo estratto on-device
    // (caselle di testo, scrittura a mano via OCR, PDF): qui non si legge
    // più dalla nota al volo. Gli studi creati prima di StudyMaterial
    // ricadono sul vecchio percorso.
    static func resolveSources(for study: Study, in context: ModelContext) -> [ResolvedSource] {
        if !study.materials.isEmpty {
            return study.materials.map {
                ResolvedSource(title: $0.title, text: $0.extractedText, isExamPaper: $0.isExamPaper)
            }
        }
        return study.sources.map { source in
            var text = ""
            if let noteID = source.noteID {
                let descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID })
                if let note = try? context.fetch(descriptor).first {
                    text = note.content
                }
            }
            return ResolvedSource(title: source.title, text: text, isExamPaper: source.isExamPaper)
        }
    }

    // MARK: - Avvio e annullamento
    //
    // La generazione era un `Task { }` fire-and-forget: nessun modo di
    // fermarla, nessuna difesa dal doppio avvio. Il registro tiene il
    // Task per studio: "Annulla" in UI diventa possibile, e un secondo
    // tocco su "Rigenera" mentre la prima gira non fa partire niente.
    @MainActor
    private static var running: [UUID: Task<Void, Never>] = [:]

    @MainActor
    static func isGenerating(_ studyID: UUID) -> Bool {
        running[studyID] != nil
    }

    @MainActor
    static func startGeneration(for study: Study, in context: ModelContext) {
        guard running[study.id] == nil else { return }
        let studyID = study.id
        running[studyID] = Task { @MainActor in
            await generateModules(for: study, in: context)
            running[studyID] = nil
        }
    }

    @MainActor
    static func cancelGeneration(for studyID: UUID) {
        running[studyID]?.cancel()
    }

    // Genera in sequenza tutti i moduli pending di uno studio, aggiornando
    // lo stato man mano (generating → ready). Da chiamare sul MainActor:
    // i @Model SwiftData vengono mutati qui.
    //
    // Se un provider AI è configurato (AIService) e i materiali hanno del
    // testo, prova la generazione reale; altrimenti (o se fallisce) usa il
    // mock — l'app resta utilizzabile senza chiavi, come da vincolo di
    // gratuità (inferenza sempre lato client, mai centralizzata).
    @MainActor
    static func generateModules(for study: Study, in context: ModelContext) async {
        let resolved = resolveSources(for: study, in: context)
        let hasText = resolved.contains { !$0.text.isEmpty }
        let pending = study.sortedModules.filter { $0.status == .pending || $0.status == .failed }
        guard !pending.isEmpty else { return }

        // Motivo per cui non si prova nemmeno a generare.
        var blockingReason: String?
        if !hasText {
            blockingReason = "I materiali non hanno testo estraibile."
        } else if !AIService.isConfigured {
            blockingReason = "Nessun provider AI configurato nel Profilo."
        }
        if let blockingReason {
            for module in pending {
                module.contentJSON = "{}"
                module.generatedByRaw = "none"
                module.generationError = blockingReason
                module.status = .failed
            }
            study.updatedAt = .now
            return
        }

        for module in pending { module.status = .generating }

        // Avviso PRIMA di generare, non dopo: se in questa sessione i
        // modelli capaci hanno già dichiarato la quota del giorno finita,
        // gli esercizi usciranno dai Lite e l'utente deve poterlo sapere
        // mentre aspetta — magari preferisce annullare e rigenerare
        // domani. Il registro conosce solo i modelli già provati, quindi
        // l'avviso può mancare (prima generazione del giorno), mai essere
        // sbagliato. La card lo mostra sotto "Generazione in corso…".
        if await AIService.capableQuotaLooksExhausted() {
            for module in pending where module.kind == .exercises {
                module.generationError = "Quota dei modelli migliori esaurita per oggi: questi esercizi usciranno dal modello veloce, più semplici del solito. Si azzera a mezzanotte (fuso del Pacifico)."
            }
        }

        // I moduli sono INDIPENDENTI: generarli in parallelo non costa
        // una chiamata in più e fa scendere il tempo totale dalla SOMMA
        // dei moduli al più lento di loro. Concorrenza limitata a 3
        // perché sul piano gratuito i modelli capaci accettano ~5
        // richieste al minuto, e il modulo esercizi ne spende due (la
        // seconda è la verifica): oltre questa soglia si inizierebbe a
        // sbattere contro il limite invece di andare più veloci.
        let jobs: [(index: Int, moduleID: UUID, kind: StudyModuleKind, options: StudyModuleOptions)] =
            pending.enumerated().compactMap { offset, module in
                guard let kind = module.kind else { return nil }
                return (offset, module.id, kind, module.options)
            }

        // Se lo studio nasce dal Vault, la generazione è guidata
        // dall'indice invece che dal troncamento cieco.
        let vaultChunks = vaultChunkInfos(for: study, in: context)

        let outcomes = await withTaskGroup(of: (Int, GenerationOutcome).self) { group -> [Int: GenerationOutcome] in
            var results: [Int: GenerationOutcome] = [:]
            var next = 0
            let maxConcurrent = 3

            func addJob(_ job: (index: Int, moduleID: UUID, kind: StudyModuleKind, options: StudyModuleOptions)) {
                let moduleID = job.moduleID
                group.addTask {
                    let progress: @Sendable (String) -> Void = { text in
                        Task { @MainActor in GenerationProgress.shared.text[moduleID] = text }
                    }
                    let outcome: GenerationOutcome
                    if vaultChunks.isEmpty {
                        outcome = await generateWithAI(for: job.kind, from: resolved, options: job.options, progress: progress)
                    } else {
                        outcome = await generateFromVault(kind: job.kind, chunks: vaultChunks, options: job.options, progress: progress)
                    }
                    return (job.index, outcome)
                }
            }

            while next < jobs.count && next < maxConcurrent {
                addJob(jobs[next]); next += 1
            }
            while let (index, outcome) = await group.next() {
                results[index] = outcome
                if next < jobs.count { addJob(jobs[next]); next += 1 }
            }
            return results
        }

        // I @Model si toccano solo qui, tornati sul MainActor.
        // Col Vault il troncamento non esiste: al suo posto parla la nota
        // di selezione dentro l'esito.
        let notice = vaultChunks.isEmpty ? truncationNotice(for: resolved) : nil
        // Perché gli esercizi sono finiti su un Lite? Da quando esiste la
        // quarantena sovraccarichi le cause sono DUE, e vanno distinte:
        // quota del giorno finita (rigenerare oggi non cambia niente)
        // oppure modelli capaci intasati (503: tra qualche minuto passa).
        // Dedurre sempre "quota esaurita" era una bugia: successo con la
        // console che mostrava 3/20 richieste usate.
        let capableExhausted = await AIService.capableQuotaLooksExhausted()
        for (offset, module) in pending.enumerated() {
            GenerationProgress.shared.text[module.id] = nil
            switch outcomes[offset] {
            case .success(let generated, let discarded, let modelID, let outcomeWarning):
                module.contentJSON = generated
                module.generatedByRaw = AIService.selectedProvider.label
                // Se gli esercizi sono finiti sul modello di ripiego, va
                // detto: la differenza si vede (domande di definizione
                // invece di esercizi con dati), e senza spiegazione
                // sembrerebbe un peggioramento inspiegabile. `modelID` è
                // quello del SUO esito, non una variabile condivisa.
                var warningParts = [notice, outcomeWarning].compactMap { $0 }
                if module.kind == .exercises, AIService.isLiteModel(modelID) {
                    warningParts.append(capableExhausted
                        ? "Quota dei modelli migliori esaurita per oggi: questi esercizi sono stati generati con il modello veloce e possono essere più semplici. Rigenerali domani per averli migliori."
                        : "I modelli migliori erano momentaneamente sovraccarichi: questi esercizi sono stati generati con il modello veloce e possono essere più semplici. Riprova a rigenerarli tra qualche minuto.")
                }
                module.generationError = warningParts.isEmpty ? nil : warningParts.joined(separator: " ")
                module.discardedCount = discarded
                module.reportedIDsJSON = "[]"
                module.status = .ready
            case .failure(let reason):
                // NIENTE contenuto d'esempio: un riassunto finto sembra
                // vero e nasconde il problema da sistemare.
                module.contentJSON = "{}"
                module.generatedByRaw = "none"
                module.generationError = reason
                module.discardedCount = 0
                module.status = .failed
            case nil:
                module.status = .failed
                module.generationError = "Generazione interrotta."
            }
        }
        study.updatedAt = .now
    }

    // MARK: - Generazione reale (provider-agnostica via AIService)
    //
    // Implementa la checklist anti-allucinazione concordata:
    // grounding stretto (solo testo dei materiali nel prompt, con
    // istruzione esplicita di non inventare), JSON validato dal decoder
    // (ciò che non decodifica si scarta e si ripiega sul mock), compiti
    // piccoli (un modulo per chiamata) e temperatura bassa (in AIService),
    // citazioni verificate letteralmente contro i materiali, doppio
    // passaggio "correttore" sugli esercizi (opt-in, `verifyExercises`).
    // Manca solo `sourceRange` per le citazioni puntuali alla pagina.

    // Esito della generazione reale: contenuto pronto (con il modello
    // che l'ha prodotto e un eventuale avviso da mostrare) o motivo del
    // fallimento (una String, non un Error: finisce dritta in UI).
    private enum GenerationOutcome: Sendable {
        case success(String, discarded: Int, modelID: String?, warning: String?)
        case failure(String)

        // Appende un avviso a un successo, lasciando intatto il resto.
        func addingWarning(_ text: String?) -> GenerationOutcome {
            guard let text, case .success(let payload, let discarded, let modelID, let warning) = self else { return self }
            let combined = [warning, text].compactMap { $0 }.joined(separator: " ")
            return .success(payload, discarded: discarded, modelID: modelID, warning: combined.isEmpty ? nil : combined)
        }
    }

    // Budget di thinking per gli esercizi e la loro verifica: INVENTARE
    // un problema con dati che tornano è ragionamento vero, e il budget
    // è la ragione per cui il Flash produce "ottimo finito 15, quanto
    // vale il duale?" e il Lite "scrivi il duale di min c'x". 2048
    // perché nelle prove i casi buoni usavano 1.400-2.000 token; i
    // 5.300-7.800 osservati erano spirale, non qualità. Lo usano i moduli
    // che inventano (esercizi, loro verifica, esercizi teorici); gli altri,
    // estrattivi, viaggiano a zero.
    private static let reasoningThinkingBudget = 2048

    // Tetto complessivo per modulo. Senza, il caso peggiore era il
    // prodotto di tutti i moltiplicatori della catena: ~40 minuti di
    // "Generazione in corso…" che nessuno poteva fermare.
    //
    // Gli esercizi hanno un tetto più alto, e NON è una preferenza: con
    // `qualityFirst` la loro catena mette il Flash lento in terza
    // posizione, quindi il caso peggiore è due 503 da ~20s + un timeout
    // pieno su quel modello + i Lite in coda. Se il tetto scade mentre
    // restano modelli liberi da provare, il risultato non è "esercizi più
    // semplici" ma "nessun esercizio" — cioè peggio di non avere tetto.
    // Serve a fermare le derive, non a impedire l'attesa che abbiamo
    // scelto di accettare.
    //
    // I numeri SEGUONO il timeout di rete di AIPurpose, e vanno rifatti
    // se quello cambia: oggi una chiamata `.generation` può prendersi
    // 240s, quindi 180 significherebbe morire prima ancora di finire il
    // PRIMO tentativo. Gli esercizi ne fanno due di chiamate — generare e
    // poi rifare i conti per verificare — e devono starci dentro
    // entrambe, altrimenti il set arriva senza verifica proprio quando è
    // stato lento, cioè quando è più grosso.
    private static func moduleDeadline(for kind: StudyModuleKind) -> TimeInterval {
        kind == .exercises ? 600 : 300
    }

    private static func generateWithAI(for kind: StudyModuleKind, from sources: [ResolvedSource], options: StudyModuleOptions, indexTopics: [String] = [], progress: @escaping @Sendable (String) -> Void) async -> GenerationOutcome {
        await withDeadline(seconds: moduleDeadline(for: kind)) {
            // Il retry sul JSON malformato resta SOLO per i provider
            // senza structured output (Apple locale, Claude): su Gemini
            // il responseSchema garantisce la sintassi, e il retry era
            // uno dei moltiplicatori del caso peggiore.
            let attempts = AIService.selectedProvider == .gemini ? 1 : 2
            var lastFailure: GenerationOutcome = .failure("Il modello non ha restituito JSON.")
            for _ in 0..<attempts {
                switch await generateOnce(for: kind, from: sources, options: options, indexTopics: indexTopics, progress: progress) {
                case .retryable(let outcome):
                    lastFailure = outcome
                case .final(let outcome):
                    return outcome
                }
            }
            return lastFailure
        }
    }

    // Fa correre l'operazione contro un timer: vince chi finisce prima,
    // l'altro viene cancellato (la cancellazione arriva fino a
    // URLSession, che interrompe la richiesta in volo).
    private static func withDeadline(seconds: TimeInterval, _ operation: @escaping @Sendable () async -> GenerationOutcome) async -> GenerationOutcome {
        await withTaskGroup(of: GenerationOutcome?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = await group.next(), let outcome = first else {
                if Task.isCancelled {
                    return .failure("Generazione annullata.")
                }
                return .failure("Tempo massimo superato (\(Int(seconds / 60)) minuti): nessun modello ha risposto in tempo. Riprova.")
            }
            return outcome
        }
    }

    // Distingue i fallimenti che un secondo tentativo può sistemare
    // (risposta malformata: il modello ritenta e di solito la scrive
    // giusta) da quelli su cui insistere è inutile o dannoso (niente
    // quota, niente rete: si sprecherebbe un'altra chiamata).
    private enum AttemptResult {
        case final(GenerationOutcome)
        case retryable(GenerationOutcome)
    }

    // I due moduli in cui il modello SCRIVE qualcosa che nei materiali
    // non c'è — tracce nuove, domande di ragionamento — e che quindi
    // vogliono il modello capace e un budget per pensare. Riassunti e
    // flashcard riordinano quello che c'è già.
    private static func invents(_ kind: StudyModuleKind) -> Bool {
        kind == .exercises || kind == .reviewPoints
    }

    private static func generateOnce(for kind: StudyModuleKind, from sources: [ResolvedSource], options: StudyModuleOptions, indexTopics: [String] = [], progress: @escaping @Sendable (String) -> Void) async -> AttemptResult {
        let prompt = buildPrompt(for: kind, from: sources, options: options, indexTopics: indexTopics)
        let raw: String
        let usedModel: String?
        var wasTruncated = false
        // Chi INVENTA passa dal modello capace; chi ESTRAE no.
        // Misurato sullo stesso prompt: il Lite produce domande di
        // definizione ("scrivi il duale di min c'x"), il Flash esercizi
        // con dati concreti da applicare ("ottimo finito 15, quanto vale
        // il duale?"). Riassunti e flashcard restano ai Lite, che sono
        // sei volte più veloci e su un compito estrattivo pareggiano.
        //
        // Gli esercizi TEORICI sono passati di qua il 2026-08-20, quando
        // hanno smesso di essere "estrai i concetti chiave" e hanno
        // iniziato a chiedere ragionamento (sotto quali ipotesi vale,
        // quando il metodo NON si applica). Lasciarli sui Lite significava
        // chiedere ragionamento al modello che sappiamo produrre
        // definizioni — cioè esattamente ciò che il loro prompt ora
        // vieta. Niente `qualityFirst` però: lì non c'è aritmetica da
        // sbagliare, quindi aspettare i 58s del Flash lento prima di
        // scendere sui Lite non si ripaga.
        switch await AIService.generate(
            prompt: prompt,
            tier: invents(kind) ? .full : .lite,
            schema: responseSchema(for: kind),
            thinkingBudget: invents(kind) ? reasoningThinkingBudget : 0,
            // Sugli esercizi si spendono TUTTI i Flash prima di scendere
            // sui Lite, anche il lento da ~58s (scelta dell'utente,
            // 2026-08-17): il declassamento qui non è un rallentamento,
            // è un esercizio peggiore.
            qualityFirst: kind == .exercises,
            onAttempt: { modelID, position, total, previousFailure in
                // Il motivo del salto va detto: tre "era sovraccarico" di
                // fila sono Google che arranca, tre "non ha risposto in
                // tempo" sono il nostro tetto di tempo troppo stretto.
                // Senza, davanti a "Provo X (3/5)" i due casi sono
                // indistinguibili.
                if let previousFailure {
                    progress("Provo \(modelID) (\(position)/\(total)) — il precedente \(previousFailure).")
                } else {
                    progress("Provo \(modelID) (\(position)/\(total))…")
                }
            }
        ) {
        case .failure(let error):
            return .final(.failure(error.message))
        case .success(let reply):
            raw = reply.text
            usedModel = reply.modelID
            wasTruncated = reply.wasTruncated
        }
        switch await parse(raw, for: kind, from: sources, options: options, modelID: usedModel, vocabulary: indexTopics) {
        case .success(let outcome):
            // Recuperato il recuperabile, ma quello che c'è è MENO di
            // quanto chiesto: dirlo, o quel numero più basso sembra una
            // scelta nostra invece di una risposta tagliata.
            return .final(wasTruncated
                ? outcome.addingWarning("La risposta si è interrotta per lunghezza: è stata salvata la parte completa, quindi qui c'è meno di quanto avevi chiesto. Rigenera per averlo intero, o chiedi meno contenuti per volta.")
                : outcome)
        case .failure(let message):
            return .retryable(.failure(message))
        }
    }

    private enum ParseResult {
        case success(GenerationOutcome)
        case failure(String)
    }

    private static func parse(_ raw: String, for kind: StudyModuleKind, from sources: [ResolvedSource], options: StudyModuleOptions, modelID: String?, vocabulary: [String] = []) async -> ParseResult {
        guard let json = AIService.extractJSON(from: raw) else {
            return .failure("Il modello non ha restituito JSON.")
        }
        // Decodifica negli DTO "da modello" (senza id) e mappa nei payload
        // veri.
        let emptyError = "Il modello non ha prodotto nessun contenuto utilizzabile."
        switch kind {
        case .summary:
            let dto: AISummaryDTO
            switch decodeDTO(AISummaryDTO.self, from: json) {
            case .failure(let message): return .failure(message)
            case .success(let decoded): dto = decoded
            }
            guard !dto.sections.isEmpty else { return .failure(emptyError) }
            return .success(encodePayload(SummaryContent(sections: dto.sections.map {
                SummarySection(title: $0.title, body: $0.body, quote: makeCitation(quote: $0.quote, source: $0.source, in: sources))
            }), modelID: modelID))
        case .exercises:
            let dto: AIExercisesDTO
            switch decodeDTO(AIExercisesDTO.self, from: json) {
            case .failure(let message): return .failure(message)
            case .success(let decoded): dto = decoded
            }
            guard !dto.exercises.isEmpty else { return .failure(emptyError) }
            // Costruito UNA volta per set: `snap` lo interroga per ogni
            // esercizio, ricostruirlo ogni volta sarebbe sprecato.
            let vocabularyIndex = TopicVocabulary(vocabulary)
            var exercises = dto.exercises.map { item in
                StudyExercise(
                    categoryRaw: ExerciseCategory.practical.rawValue,
                    difficultyRaw: (ExerciseDifficulty(rawValue: item.difficulty ?? "") ?? .base).rawValue,
                    topic: snap(item.topic ?? "Senza argomento", in: vocabularyIndex),
                    prompt: item.prompt,
                    steps: item.steps,
                    answer: item.answer,
                    sourceTitle: item.source,
                    quote: makeCitation(quote: item.quote, source: item.source, in: sources),
                    checkExpression: item.checkExpression,
                    verificationRaw: ExerciseVerification.notChecked.rawValue,
                    originRaw: (ExerciseOrigin(rawValue: item.origin ?? "") ?? .invented).rawValue,
                    figureTikZ: item.figureTikZ,
                    figureExpected: figureIsMissing(declared: item.figuraServe, tikz: item.figureTikZ, prompt: item.prompt)
                )
            }
            // Doppio passaggio: gli esercizi che non reggono una seconda
            // risoluzione indipendente vengono scartati qui, non mostrati
            // con un avviso — una soluzione guidata sbagliata è peggio di
            // un esercizio in meno.
            var discarded = 0
            if options.verifyExercises {
                let verdicts = await verifyExercises(exercises, from: sources)
                if !verdicts.isEmpty {
                    var kept: [StudyExercise] = []
                    for (index, var exercise) in exercises.enumerated() {
                        // NESSUN VERDETTO PER QUESTO INDICE. Il correttore
                        // ha risposto, ma non su di lui (risposta parziale,
                        // indici saltati). Prima questo caso valeva
                        // "promosso": l'esercizio usciva col badge "risolto
                        // due volte" senza che nessuno l'avesse risolto una
                        // seconda volta. Ora si tiene — scartarlo sarebbe
                        // punirlo per una mancanza NOSTRA — ma resta non
                        // marcato, che è la verità.
                        guard let verdict = verdicts[index] else {
                            kept.append(exercise)
                            continue
                        }
                        if verdict.correct {
                            exercise.verificationRaw = ExerciseVerification.agreed.rawValue
                            // LA DIFFICOLTÀ LA DICHIARA CHI HA RISOLTO,
                            // non chi ha inventato. Il generatore gonfia
                            // l'etichetta (dice "avanzato" e consegna un
                            // esercizio da un passaggio); il correttore ha
                            // appena rifatto il conto ed è l'unico in
                            // posizione di graduarlo su ciò che è servito
                            // davvero.
                            if let graded = verdict.difficulty {
                                exercise.difficultyRaw = graded.rawValue
                            }
                            kept.append(exercise)
                        } else {
                            discarded += 1
                        }
                    }
                    // Se la verifica boccia tutto, è più probabile che sia
                    // andata storta lei che non che ogni esercizio sia
                    // sbagliato: si tengono gli originali non marcati.
                    if kept.isEmpty {
                        discarded = 0
                    } else {
                        exercises = kept
                    }
                }
            }
            return .success(encodePayload(ExerciseSetContent(exercises: exercises), discarded: discarded, modelID: modelID))
        case .reviewPoints:
            let dto: AIReviewPointsDTO
            switch decodeDTO(AIReviewPointsDTO.self, from: json) {
            case .failure(let message): return .failure(message)
            case .success(let decoded): dto = decoded
            }
            guard !dto.points.isEmpty else { return .failure(emptyError) }
            // Stesso vocabolario degli esercizi da risolvere, e non è un
            // dettaglio: se "programmazione lineare" qui e "PL" là restano
            // due stringhe diverse, nell'analisi diventano due argomenti e
            // la teoria non si somma mai alla pratica.
            let pointVocabulary = TopicVocabulary(vocabulary)
            return .success(encodePayload(ReviewPointsContent(points: dto.points.map {
                ReviewPoint(statement: $0.statement, question: $0.question, answer: $0.answer,
                            quote: makeCitation(quote: $0.quote, source: $0.source, in: sources),
                            topic: $0.topic.map { snap($0, in: pointVocabulary) })
            }), modelID: modelID))
        case .flashcards:
            let dto: AIFlashcardsDTO
            switch decodeDTO(AIFlashcardsDTO.self, from: json) {
            case .failure(let message): return .failure(message)
            case .success(let decoded): dto = decoded
            }
            guard !dto.cards.isEmpty else { return .failure(emptyError) }
            return .success(encodePayload(FlashcardsContent(cards: dto.cards.map {
                Flashcard(front: $0.front, back: $0.back, quote: makeCitation(quote: $0.quote, source: $0.source, in: sources))
            }), modelID: modelID))
        }
    }

    // MARK: - Generazione guidata dal Vault (passo 3, deciso 2026-08-15)
    //
    // Con uno studio nato dal Vault il prompt non si riempie più "alla
    // cieca" coi primi 100k caratteri: l'indice decide COSA entra.
    // - esercizi/flashcard/ripasso: stesso numero di chiamate di oggi,
    //   ma i materiali sono i chunk scelti per copertura (tutti gli
    //   argomenti, temi d'esame prioritari per gli esercizi), e la FASE 1
    //   degli esercizi parte dagli argomenti dell'indice;
    // - riassunto: deve coprire TUTTO, quindi itera sui chunk in Lite e
    //   cuce le sezioni nell'ordine del corso.

    // Snapshot Sendable di un chunk: i @Model restano sul MainActor.
    private struct VaultChunkInfo: Sendable {
        let order: Int
        let title: String
        let text: String
        let topics: [String]
        let nature: String
        let isExamPaper: Bool
        // Quante pagine copre: serve alla nota in UI, che parla allo
        // studente in pagine, non in "blocchi" (termine interno).
        // 0 = non lo sappiamo (pseudo-chunk di materiali non-Vault).
        let pageCount: Int
    }

    @MainActor
    private static func vaultChunkInfos(for study: Study, in context: ModelContext) -> [VaultChunkInfo] {
        let ids = Set(study.sources.compactMap(\.vaultDocumentID))
        guard !ids.isEmpty else { return [] }
        let descriptor = FetchDescriptor<VaultDocument>()
        let documents = ((try? context.fetch(descriptor)) ?? []).filter { ids.contains($0.id) }
        var infos: [VaultChunkInfo] = []
        for document in documents {
            let chunks = document.sortedChunks
            if chunks.isEmpty {
                // Documento letto ma non ancora spezzato in chunk: entra
                // intero come un blocco unico, senza etichette.
                let text = document.fullText
                guard !text.isEmpty else { continue }
                infos.append(VaultChunkInfo(order: infos.count, title: document.title, text: text, topics: [], nature: "mixed", isExamPaper: document.isExamPaper, pageCount: document.readCount))
            } else {
                for chunk in chunks {
                    let text = chunk.text
                    guard !text.isEmpty else { continue }
                    infos.append(VaultChunkInfo(
                        order: infos.count,
                        title: "\(document.title) (pagg. \(chunk.pageStart + 1)-\(chunk.pageEnd + 1))",
                        text: text,
                        topics: chunk.topics,
                        nature: chunk.natureRaw,
                        isExamPaper: document.isExamPaper,
                        pageCount: chunk.pageEnd - chunk.pageStart + 1
                    ))
                }
            }
        }
        // Studio misto: i materiali NON-Vault entrano come pseudo-chunk,
        // così niente si perde per aver mescolato le sorgenti.
        if !infos.isEmpty {
            for material in study.materials where material.kind != .vault && !material.extractedText.isEmpty {
                infos.append(VaultChunkInfo(order: infos.count, title: material.title, text: material.extractedText, topics: [], nature: "mixed", isExamPaper: material.isExamPaper, pageCount: 0))
            }
        }
        return infos
    }

    private static func generateFromVault(kind: StudyModuleKind, chunks allChunks: [VaultChunkInfo], options: StudyModuleOptions, progress: @escaping @Sendable (String) -> Void) async -> GenerationOutcome {
        // Argomenti scelti in creazione: si tengono solo i chunk che ne
        // trattano almeno uno. I chunk senza etichette (documenti non
        // ancora indicizzati) restano: escluderli significherebbe
        // buttare materiale per un indice mancante, non per una scelta.
        let chunks = filtered(allChunks, by: options.selectedTopics)
        switch kind {
        case .summary:
            // Il riassunto è di teoria: i chunk di soli esercizi/temi
            // d'esame non c'entrano (a meno che non ci sia altro).
            let theory = chunks.filter { !$0.isExamPaper && $0.nature != "exercises" }
            return await generateVaultSummary(chunks: theory.isEmpty ? chunks : theory, options: options, progress: progress)
        default:
            let (selected, note) = selectChunks(chunks, for: kind, budget: materialsBudget)
            let sources = selected.map { ResolvedSource(title: $0.title, text: $0.text, isExamPaper: $0.isExamPaper) }
            // Il vocabolario che il modello deve usare per "topic": se
            // l'utente ha scelto, sono le SUE etichette; altrimenti
            // quelle dell'indice. In entrambi i casi sono stabili tra
            // generazioni, ed è ciò che tiene insieme i progressi.
            let vocabulary = options.selectedTopics.isEmpty ? orderedTopics(of: chunks) : options.selectedTopics
            let outcome = await generateWithAI(for: kind, from: sources, options: options, indexTopics: vocabulary, progress: progress)
            return outcome.addingWarning(note)
        }
    }

    // Riporta il "topic" scritto dal modello all'etichetta esatta del
    // vocabolario. Il prompt lo vieta già, ma il prompt è una preghiera:
    // questa è la garanzia. Senza, "Dualità in PL" e "dualità in PL"
    // restano due argomenti diversi per l'analisi dei progressi, che
    // raggruppa sulla stringa nuda.
    //
    // Due criteri, entrambi conservativi: uguaglianza a meno di
    // maiuscole/spazi, oppure contenimento (il modello tende ad allungare
    // — "dualità in PL (problema duale)"). Se non riconosce nulla, si
    // tiene ciò che ha scritto il modello: inventare un aggancio sarebbe
    // peggio di un argomento in più.
    private static func snap(_ topic: String, in vocabulary: TopicVocabulary) -> String {
        guard !vocabulary.isEmpty else { return topic }
        return vocabulary.canonical(for: topic) ?? topic
    }

    private static func filtered(_ chunks: [VaultChunkInfo], by topics: [String]) -> [VaultChunkInfo] {
        guard !topics.isEmpty else { return chunks }
        // Il confronto passa dalla chiave canonica: selezionare
        // "problema di trasporto" deve tenere anche i chunk etichettati
        // "problemi di trasporto", che è lo stesso argomento.
        let wanted = Set(topics.map { TopicKey.key($0) })
        let kept = chunks.filter { chunk in
            chunk.topics.isEmpty || chunk.topics.contains { wanted.contains(TopicKey.key($0)) }
        }
        // Se il filtro non lascia niente (etichette disallineate), meglio
        // generare su tutto che fallire il modulo.
        return kept.isEmpty ? chunks : kept
    }

    // Selezione nel budget: per gli esercizi prima i temi d'esame e i
    // blocchi di esercizi (sono la materia prima dei "practical"), poi
    // la teoria in ordine di copertura; per gli altri moduli solo la
    // copertura. L'ordine di lettura finale resta quello del corso.
    private static func selectChunks(_ chunks: [VaultChunkInfo], for kind: StudyModuleKind, budget: Int) -> (selected: [VaultChunkInfo], note: String?) {
        let prioritized: [VaultChunkInfo]
        switch kind {
        case .exercises:
            let examLike = chunks.filter { $0.isExamPaper || $0.nature == "exercises" }
            let theory = chunks.filter { !($0.isExamPaper || $0.nature == "exercises") }
            prioritized = examLike + coverageOrdered(theory)
        default:
            prioritized = coverageOrdered(chunks)
        }
        var selected: [VaultChunkInfo] = []
        var used = 0
        for chunk in prioritized where used + chunk.text.count <= budget {
            selected.append(chunk)
            used += chunk.text.count
        }
        if selected.isEmpty, let first = prioritized.first {
            selected = [first]
        }
        selected.sort { $0.order < $1.order }
        return (selected, selectionNote(selected: selected, of: chunks))
    }

    // La nota per la card, quando è entrata una selezione e non tutto.
    // Due regole nate da una domanda dell'utente ("cosa sono i blocchi?"):
    // si parla in PAGINE, non in "blocchi" (termine interno), e la
    // copertura si CALCOLA invece di dichiararla — se il pezzo rimasto
    // fuori conteneva un argomento unico, va detto quale, non nascosto
    // dietro un "tutti coperti" di default.
    private static func selectionNote(selected: [VaultChunkInfo], of chunks: [VaultChunkInfo]) -> String? {
        guard selected.count < chunks.count else { return nil }

        let selectedPages = selected.reduce(0) { $0 + $1.pageCount }
        let totalPages = chunks.reduce(0) { $0 + $1.pageCount }
        // Con gli pseudo-chunk (pageCount 0) il conto in pagine mentirebbe:
        // si ripiega sulle parti.
        let extent = (selectedPages > 0 && totalPages > 0 && chunks.allSatisfy { $0.pageCount > 0 })
            ? "\(selectedPages) pagine su \(totalPages)"
            : "\(selected.count) parti su \(chunks.count)"

        let covered = Set(selected.flatMap(\.topics).map { TopicKey.key($0) })
        let missing = orderedTopics(of: chunks).filter { !covered.contains(TopicKey.key($0)) }

        if missing.isEmpty {
            return "Il materiale supera lo spazio di una generazione: l'indice del Vault ha scelto le parti più utili (\(extent)). Tutti gli argomenti sono coperti."
        }
        let listed = missing.prefix(3).joined(separator: ", ")
        let more = missing.count > 3 ? " e altri \(missing.count - 3)" : ""
        return "Il materiale supera lo spazio di una generazione: usate \(extent). Argomenti rimasti fuori: \(listed)\(more). Per coprirli, crea uno studio selezionando solo quelli."
    }

    // Prima i chunk che aggiungono argomenti nuovi (in ordine di corso),
    // poi gli approfondimenti: ogni argomento compare almeno una volta
    // prima di spendere budget due volte sullo stesso.
    private static func coverageOrdered(_ chunks: [VaultChunkInfo]) -> [VaultChunkInfo] {
        var covered: Set<String> = []
        var primary: [VaultChunkInfo] = []
        var secondary: [VaultChunkInfo] = []
        for chunk in chunks {
            let fresh = chunk.topics.map { TopicKey.key($0) }.filter { !covered.contains($0) }
            if chunk.topics.isEmpty || !fresh.isEmpty {
                covered.formUnion(fresh)
                primary.append(chunk)
            } else {
                secondary.append(chunk)
            }
        }
        return primary + secondary
    }

    // Gli argomenti dei chunk, nell'ordine del corso e CONSOLIDATI: le
    // varianti della stessa etichetta collassano su una canonica, che è
    // ciò che finisce nel prompt come vocabolario e nella nota di
    // selezione. Senza, una dispensa da ~17 chunk arrivava a un centinaio
    // di voci quasi-duplicate.
    private static func orderedTopics(of chunks: [VaultChunkInfo]) -> [String] {
        var seen: Set<String> = []
        var raw: [String] = []
        for chunk in chunks {
            for topic in chunk.topics where seen.insert(topic.lowercased()).inserted {
                raw.append(topic)
            }
        }
        return TopicVocabulary.consolidated(raw)
    }

    // Il riassunto a mappa: una chiamata Lite per chunk, 3 in parallelo,
    // sezioni cucite nell'ordine del corso. È il modulo che il
    // troncamento danneggiava di più: così copre il corso INTERO.
    private static func generateVaultSummary(chunks: [VaultChunkInfo], options: StudyModuleOptions, progress: @escaping @Sendable (String) -> Void) async -> GenerationOutcome {
        await withDeadline(seconds: 360) {
            let total = chunks.count
            let results = await withTaskGroup(of: (Int, [SummarySection]?).self) { group -> [Int: [SummarySection]] in
                var out: [Int: [SummarySection]] = [:]
                var next = 0
                var done = 0
                let maxConcurrent = 3

                func add(_ index: Int) {
                    let chunk = chunks[index]
                    group.addTask { (index, await summarizeChunk(chunk, options: options)) }
                }

                while next < chunks.count && next < maxConcurrent {
                    add(next); next += 1
                }
                while let (index, sections) = await group.next() {
                    done += 1
                    // In pagine, mai in "blocchi": termine interno
                    // (stessa regola della nota di selezione).
                    progress("Riassumo: parte \(done) di \(total) del materiale…")
                    if let sections { out[index] = sections }
                    if next < chunks.count { add(next); next += 1 }
                }
                return out
            }
            let ordered = (0..<chunks.count).compactMap { results[$0] }.flatMap { $0 }
            guard !ordered.isEmpty else {
                return .failure("Il riassunto non è riuscito su nessuna parte del materiale. Riprova tra qualche minuto.")
            }
            let failedChunks = chunks.indices.filter { results[$0] == nil }
            var warning: String?
            if !failedChunks.isEmpty {
                let failedPages = failedChunks.reduce(0) { $0 + chunks[$1].pageCount }
                let extent = failedPages > 0 ? "circa \(failedPages) pagine" : "\(failedChunks.count) parti su \(chunks.count)"
                warning = "Riassunto incompleto: mancano \(extent) del materiale. Rigenera il modulo per completarlo."
            }
            return encodePayload(SummaryContent(sections: ordered), warning: warning)
        }
    }

    private static func summarizeChunk(_ chunk: VaultChunkInfo, options: StudyModuleOptions) async -> [SummarySection]? {
        let source = ResolvedSource(title: chunk.title, text: chunk.text, isExamPaper: chunk.isExamPaper)
        let prompt = buildPrompt(for: .summary, from: [source], options: options)
        guard case .success(let reply) = await AIService.generate(prompt: prompt, tier: .lite, schema: responseSchema(for: .summary), thinkingBudget: 0),
              let json = AIService.extractJSON(from: reply.text),
              case .success(let dto) = decodeDTO(AISummaryDTO.self, from: json),
              !dto.sections.isEmpty else {
            return nil
        }
        return dto.sections.map {
            SummarySection(title: $0.title, body: $0.body, quote: makeCitation(quote: $0.quote, source: $0.source, in: [source]))
        }
    }

    // MARK: - Correzione mirata di un singolo esercizio
    //
    // Rigenera SOLO l'esercizio segnalato, passando al modello cosa non
    // andava. Una chiamata invece di rifare tutto il modulo: costa meno
    // quota e soprattutto non butta via gli altri esercizi, che magari
    // erano buoni. Se qualcosa va storto, l'esercizio originale resta
    // dov'è — meglio tenersi quello segnalato che perderlo.
    @MainActor
    static func regenerateExercise(
        id exerciseID: UUID,
        in module: StudyModule,
        study: Study,
        feedback: String,
        context: ModelContext
    ) async -> String? {
        guard var content = module.decodeContent(ExerciseSetContent.self),
              let index = content.exercises.firstIndex(where: { $0.id == exerciseID }) else {
            return "Esercizio non trovato nel modulo."
        }
        let old = content.exercises[index]
        // Argomenti già coperti dagli altri esercizi: il sostituto non
        // deve sovrapporsi a loro, altrimenti la copertura si restringe
        // proprio mentre stiamo correggendo.
        let otherTopics = content.exercises.enumerated()
            .filter { $0.offset != index }
            .map(\.element.topic)
        let sources = resolveSources(for: study, in: context)
        guard sources.contains(where: { !$0.text.isEmpty }) else {
            return "Senza testo nei materiali non posso rigenerare l'esercizio."
        }
        // Vocabolario per lo `snap` del sostituto: le etichette scelte in
        // creazione se ci sono, altrimenti quelle già in uso nel set
        // (che sono a loro volta passate da snap alla generazione). Senza
        // questo, un esercizio rigenerato rientrava con l'argomento
        // scritto a modo suo e spezzava in due le statistiche — cioè
        // disfaceva proprio ciò per cui `snap` esiste.
        let vocabulary: TopicVocabulary = {
            let chosen = module.options.selectedTopics
            guard chosen.isEmpty else { return TopicVocabulary(chosen) }
            var seen: Set<String> = []
            let used = content.exercises.map(\.topic).filter { topic in
                !topic.isEmpty && seen.insert(topic.lowercased()).inserted
            }
            return TopicVocabulary(used)
        }()

        let prompt = """
        \(commonPreamble(from: sources))

        Un esercizio che avevi generato è stato SEGNALATO come sbagliato dallo studente. Riscrivilo da capo correggendo il problema.

        ESERCIZIO DA CORREGGERE:
        Traccia: \(old.prompt)
        Risposta data: \(old.answer)

        COSA NON VA (segnalato dallo studente): \(feedback.isEmpty ? "non specificato: ricontrolla soprattutto la correttezza della soluzione" : feedback)

        Genera UN SOLO esercizio sostitutivo, sullo stesso argomento ("\(old.topic)") e della stessa difficoltà, che non ripeta l'errore segnalato.
        Gli altri esercizi del set coprono già questi argomenti, NON generarne uno su di essi: \(otherTopics.isEmpty ? "nessuno" : otherTopics.joined(separator: ", ")). Valgono tutte le regole di prima: traccia autosufficiente, formule in LaTeX tra $$ su riga propria, citazione verbatim dai materiali.
        Vale anche la regola sulla figura: indica SEMPRE "figuraServe" (true/false) applicando lo stesso criterio operativo — serve quando la traccia contiene informazione non lineare che lo studente dovrebbe disegnarsi da sé per risolverla, non quando il disegno sarebbe decorazione. Se è true, "figureTikZ" è obbligatorio: solo il codice da \\begin{tikzpicture} a \\end{tikzpicture}, con dati IDENTICI a quelli della NUOVA traccia (la figura del vecchio esercizio non si riusa: i dati sono cambiati). Librerie disponibili: pgfplots, automata, positioning, arrows.meta, matrix, calc, shapes; circuitikz e tikz-cd non ci sono.
        Schema: {"exercises":[{"difficulty":"base|medio|avanzato","topic":"...","prompt":"...","steps":["..."],"answer":"...","source":"...","quote":"...","checkExpression":"...","origin":"invented|fromMaterials","figuraServe":true,"figureTikZ":"..."}]}
        """

        guard case .success(let reply) = await AIService.generate(prompt: prompt, tier: .full, schema: exercisesSchema, thinkingBudget: reasoningThinkingBudget, qualityFirst: true),
              let json = AIService.extractJSON(from: reply.text),
              case .success(let dto) = decodeDTO(AIExercisesDTO.self, from: json),
              let item = dto.exercises.first else {
            return "La rigenerazione non è riuscita. L'esercizio segnalato è rimasto invariato."
        }

        content.exercises[index] = StudyExercise(
            categoryRaw: ExerciseCategory.practical.rawValue,
            difficultyRaw: (ExerciseDifficulty(rawValue: item.difficulty ?? "") ?? old.difficulty).rawValue,
            topic: snap(item.topic ?? old.topic, in: vocabulary),
            prompt: item.prompt,
            steps: item.steps,
            answer: item.answer,
            sourceTitle: item.source,
            quote: makeCitation(quote: item.quote, source: item.source, in: sources),
            checkExpression: item.checkExpression,
            originRaw: (ExerciseOrigin(rawValue: item.origin ?? "") ?? .invented).rawValue,
            // La figura del VECCHIO esercizio non si eredita: la traccia
            // è stata riscritta con dati diversi, e un disegno che non
            // corrisponde è peggio di nessun disegno. Si tiene solo
            // quella nuova, che verrà compilata alla prima apertura.
            figureTikZ: item.figureTikZ,
            figureExpected: figureIsMissing(declared: item.figuraServe, tikz: item.figureTikZ, prompt: item.prompt)
        )
        module.encodeContent(content)
        // La segnalazione si chiude da sola: il contenuto che l'aveva
        // provocata non esiste più.
        module.clearReport(exerciseID)
        study.updatedAt = .now
        return nil
    }

    // MARK: - Doppio passaggio
    //
    // Una sola chiamata per l'intero set (non una per esercizio): con il
    // free tier la quota è la risorsa scarsa. Il verificatore riceve i
    // materiali e le tracce, risolve per conto suo e dichiara per ognuno
    // se la risposta proposta regge.
    private static func verifyExercises(_ exercises: [StudyExercise], from sources: [ResolvedSource]) async -> [Int: ExerciseVerdict] {
        guard !exercises.isEmpty else { return [:] }
        var list = ""
        for (index, exercise) in exercises.enumerated() {
            // I PASSAGGI vanno mostrati: senza, il correttore rifà il
            // conto alla cieca e basta un percorso diverso per far
            // divergere il risultato — e l'esercizio spariva.
            let steps = exercise.steps.isEmpty
                ? ""
                : "\nPASSAGGI PROPOSTI:\n" + exercise.steps.enumerated()
                    .map { "  \($0.offset + 1)) \($0.element)" }
                    .joined(separator: "\n")
            list += "\n[\(index)] TRACCIA: \(exercise.prompt)\(steps)\nRISPOSTA PROPOSTA: \(exercise.answer)\n"
        }
        let prompt = """
        Sei un correttore. Per ogni esercizio qui sotto risolvilo per conto tuo partendo DAI DATI DELLA TRACCIA, poi giudica se la RISPOSTA PROPOSTA è corretta.

        IL CRITERIO È UNO SOLO: il risultato proposto è sbagliato rispetto ai dati della traccia? Sono tutti esercizi da risolvere facendo un conto, quindi il giudice sei TU che lo rifai. I materiali qui sotto servono a ricordarti il METODO, le condizioni di applicabilità e le convenzioni della materia — un esercizio che le contraddice è sbagliato anche se l'aritmetica torna — ma NON sono la fonte con cui verificare i numeri: quelli si verificano ricalcolandoli.

        NON sono motivi di bocciatura, e sbagliare qui fa danno:
        - che l'esercizio non si trovi nei materiali. Le tracce sono INVENTATE APPOSTA, ispirate al corso: cercarle nei materiali e non trovarle è il comportamento previsto, non un difetto.
        - che i dati siano diversi da quelli degli esempi del corso. Devono esserlo.
        - che tu avresti impostato il problema in un altro modo, se anche la strada proposta arriva al risultato giusto.

        In entrambi i casi boccia anche quando: i passaggi si contraddicono fra loro o con la risposta, la traccia non porta abbastanza per poter rispondere, oppure la risposta non risponde alla domanda posta.

        COME RISPONDERE — l'ordine dei campi è vincolante e va rispettato:
        1) "risultato": il risultato a cui sei arrivato TU rifacendo il conto. Scrivilo per primo, PRIMA di formulare il giudizio. Se la traccia non porta i dati per arrivarci, scrivi qui che cosa manca.
        2) "correct": true solo se il tuo risultato e la RISPOSTA PROPOSTA coincidono (o sono la stessa cosa scritta in forma diversa). Se hai ottenuto un risultato diverso, è false — anche se la strada proposta ti sembra ragionevole.
        3) "difficolta": il livello VERO dell'esercizio, misurato su quello che hai dovuto fare TU per risolverlo, non su quello che l'esercizio dichiara di essere. Un esercizio che si risolve in un passaggio è "base" anche se si presenta come avanzato.

        \(Self.difficultyMeaning)

        Rispondi SOLO con JSON valido, senza testo attorno, nel formato: {"verdicts":[{"index":0,"risultato":"...","correct":true,"difficolta":"medio"}]}

        MATERIALI (estratto di contesto):
        \(String(materialsBlock(from: sources).prefix(20000)))

        ESERCIZI DA VERIFICARE:
        \(list)
        """
        // Stesso budget di thinking degli esercizi: risolvere i problemi
        // per conto proprio è ragionamento quanto scriverli. E stesso
        // `qualityFirst`, per lo stesso motivo: un Lite che fa il
        // "correttore severo" di esercizi è un giudice debole, e il
        // secondo passaggio vale esattamente per la sua severità.
        guard case .success(let reply) = await AIService.generate(prompt: prompt, tier: .full, schema: verdictsSchema, thinkingBudget: reasoningThinkingBudget, qualityFirst: true),
              let json = AIService.extractJSON(from: reply.text),
              let data = json.data(using: .utf8),
              let dto = try? JSONDecoder().decode(AIVerdictsDTO.self, from: data) else {
            // Verifica non riuscita: non si scarta nulla (meglio un
            // esercizio non verificato che perderlo per un errore nostro).
            return [:]
        }
        var result: [Int: ExerciseVerdict] = [:]
        for verdict in dto.verdicts {
            result[verdict.index] = ExerciseVerdict(
                correct: verdict.correct,
                difficulty: verdict.difficolta.flatMap { ExerciseDifficulty(rawValue: $0.lowercased()) }
            )
        }
        return result
    }

    private struct AIVerdictsDTO: Decodable {
        struct Verdict: Decodable {
            var index: Int
            var correct: Bool
            // Il risultato che il correttore ha ottenuto da solo. Non si
            // mostra da nessuna parte: serve a farglielo CALCOLARE prima
            // di giudicare (vedi verdictsSchema).
            var risultato: String?
            var difficolta: String?
        }
        var verdicts: [Verdict]
    }

    // Esito del correttore su un esercizio: se il conto torna e quanto è
    // difficile DAVVERO, misurato da chi l'ha appena risolto invece che
    // da chi l'ha inventato.
    private struct ExerciseVerdict {
        var correct: Bool
        var difficulty: ExerciseDifficulty?
    }

    private static func encodePayload(_ payload: some Encodable, discarded: Int = 0, modelID: String? = nil, warning: String? = nil) -> GenerationOutcome {
        guard let data = try? JSONEncoder().encode(payload), let string = String(data: data, encoding: .utf8) else {
            return .failure("Errore interno di codifica del contenuto.")
        }
        return .success(string, discarded: discarded, modelID: modelID, warning: warning)
    }

    // Il blocco materiali è l'UNICA conoscenza ammessa (grounding stretto).
    // Cap sulla lunghezza per non sforare i limiti del free tier.
    // Budget complessivo di caratteri dei materiali in un prompt. Non è
    // un limite del modello ma una scelta: tenere il contesto compatto
    // migliora la qualità dell'estrazione e consuma meno quota.
    // Alzato da 24.000 a 100.000 caratteri (~25k token). Il valore
    // iniziale era tarato sulla prudenza, ma con materiali VERI — cinque
    // temi d'esame con soluzioni — significava dare al modello solo le
    // prime pagine di ciascuno e generare su una frazione del programma.
    // I flash correnti accettano contesti enormi (1M token); il vincolo
    // pratico è semmai il tetto di 250k token al minuto, e con ~25k per
    // chiamata e 6 chiamate per studio ci si sta comodamente dentro.
    private static let materialsBudget = 100000

    // Il budget si distribuisce in modo equo, ma quello che i materiali
    // corti non usano viene riciclato dai lunghi: con una nota di 200
    // caratteri e una dispensa di 100.000, dare metà budget a testa
    // sprecherebbe la metà del contesto.
    private static func materialsBlock(from sources: [ResolvedSource]) -> String {
        let texts = sources.map(\.text)
        let allowances = distribute(budget: materialsBudget, among: texts.map(\.count))

        var block = ""
        for (index, source) in sources.enumerated() {
            let role = source.isExamPaper ? "TEMA D'ESAME" : "MATERIALE DI TEORIA"
            block += "--- \(role): \(source.title) ---\n"
            if source.text.isEmpty {
                block += "(nessun testo estratto: usa solo il titolo, non inventare contenuti)\n"
                continue
            }
            let allowance = allowances[index]
            if source.text.count > allowance {
                block += String(source.text.prefix(allowance))
                block += "\n[…materiale troncato: sono stati usati i primi \(allowance) caratteri di \(source.text.count)]\n"
            } else {
                block += source.text + "\n"
            }
        }
        return block
    }

    // Quanti caratteri tocca a ciascun materiale: si parte da una quota
    // uguale per tutti e si redistribuisce ripetutamente l'avanzo di chi
    // sta sotto la propria quota, finché non c'è più niente da spartire.
    private static func distribute(budget: Int, among sizes: [Int]) -> [Int] {
        guard !sizes.isEmpty else { return [] }
        var allowances = [Int](repeating: 0, count: sizes.count)
        var remaining = budget
        var open = Set(sizes.indices)

        while !open.isEmpty && remaining > 0 {
            let share = remaining / open.count
            if share == 0 { break }
            var consumed = 0
            var satisfied: [Int] = []
            for index in open where sizes[index] <= share {
                allowances[index] = sizes[index]
                consumed += sizes[index]
                satisfied.append(index)
            }
            if satisfied.isEmpty {
                // Restano solo materiali più lunghi della quota: si spartisce.
                for index in open { allowances[index] = share }
                remaining = 0
                break
            }
            open.subtract(satisfied)
            remaining -= consumed
        }
        return allowances
    }

    // Un materiale è stato tagliato in questa generazione? Serve a dirlo
    // in UI: un riassunto fatto sul 20% di una dispensa non è un
    // riassunto della dispensa, e l'utente deve saperlo.
    static func truncationNotice(for sources: [ResolvedSource]) -> String? {
        let allowances = distribute(budget: materialsBudget, among: sources.map(\.text.count))
        let truncated = sources.enumerated().filter { $0.element.text.count > allowances[$0.offset] }
        guard !truncated.isEmpty else { return nil }
        // Solo il conteggio e la percentuale, non l'elenco dei nomi: con
        // cinque PDF dal titolo lungo il messaggio diventava più lungo del
        // contenuto della card e ne sfondava il layout.
        let shares = truncated.map { allowances[$0.offset] * 100 / max($0.element.text.count, 1) }
        let averageShare = shares.reduce(0, +) / max(shares.count, 1)
        if truncated.count == 1 {
            return "Materiale troppo lungo: usata circa la prima parte (~\(averageShare)%)."
        }
        return "\(truncated.count) materiali troppo lunghi: di ciascuno è stata usata circa la prima parte (~\(averageShare)%)."
    }

    // Preambolo comune a tutti i prompt di generazione: regole di
    // grounding, formattazione e citazioni, più il blocco dei materiali.
    // Estratto perché lo usa anche la rigenerazione del singolo esercizio.
    private static func commonPreamble(from sources: [ResolvedSource]) -> String {
        """
        Sei un assistente di studio per uno studente del Politecnico di Milano.
        Usa ESCLUSIVAMENTE i materiali qui sotto: non aggiungere teoria di tua conoscenza.
        Se un'informazione non è nei materiali, scrivi "non presente nei materiali" invece di inventarla.
        Rispondi in italiano, SOLO con un oggetto JSON valido conforme allo schema indicato, senza testo attorno né recinzioni markdown.

        FORMATTAZIONE — regole obbligatorie (valgono per il testo che SCRIVI TU, mai per il campo "quote"):
        - Il testo viene reso in Markdown: usa **grassetto** per i dati che contano ed elenchi con "- " dove aiutano.
        - La matematica va SEMPRE in LaTeX, in due registri:
          · IN LINEA, tra $ … $, per simboli ed espressioni corte che vivono dentro una frase: "Sia $X$ una variabile aleatoria con $\\lambda > 0$ e $k \\in \\mathbb{N}$". La frase resta UNA frase scorrevole.
          · A DISPLAY, tra $$ … $$ su riga propria, SOLO per le equazioni che meritano una riga: definizioni, formule risolutive, matrici, sistemi, passaggi lunghi.
        - NON usare MAI $$ per un simbolo solo o un'espressione corta in mezzo a una frase: spezzerebbe il testo in righe centrate, rendendolo illeggibile.
        - Ogni $$ aperto va CHIUSO nella stessa formula: un $$ senza chiusura rompe la resa di tutto il testo che segue.
        - NON scrivere MAI notazione a caratteri tipo "x^3 - 3x^2 + 2x", "sqrt(2)", "integrale da 1 a 2": è illeggibile. Scrivi invece $x^3 - 3x^2 + 2x$ in linea, oppure su riga propria:
        $$f(x) = x^3 - 3x^2 + 2x + 1$$
        - ATTENZIONE AGLI ESCAPE: stai scrivendo LaTeX dentro JSON, dove ogni backslash va RADDOPPIATO. Scrivi "\\\\frac", "\\\\theta", "\\\\begin"; e l'a-capo di una matrice, che in LaTeX è "\\\\", dentro il JSON diventa quattro backslash.
        - Matrici, vettori e sistemi vanno SEMPRE dentro $$ con l'ambiente giusto (pmatrix, bmatrix, cases), mai come elenchi di numeri o tabelle di testo. Esempio:
        $$A = \\begin{pmatrix} 8 & 1 \\\\ 1 & 4 \\end{pmatrix}$$

        REGOLA SULLE CITAZIONI: ogni elemento che produci deve includere "quote", cioè un frammento COPIATO ALLA LETTERA dai materiali (10-200 caratteri, identico carattere per carattere) che sostiene ciò che affermi, e "source" con il titolo esatto del materiale da cui l'hai preso.
        Il campo "quote" è l'UNICA ECCEZIONE alle regole di formattazione qui sopra: NON convertirlo in LaTeX, NON aggiungere $$, NON metterci grassetti, NON sistemare la notazione. Va incollato esattamente come appare nel materiale, anche se la matematica risulta scritta male.
        Non riformulare, non correggere e non abbreviare le citazioni: vengono confrontate automaticamente con il testo originale e, se non corrispondono, il contenuto viene marcato come non verificato.
        Se per un elemento non esiste un passaggio letterale a supporto, ometti "quote" invece di inventarne uno.

        MATERIALI:
        \(materialsBlock(from: sources))

        """
    }

    // MARK: - responseSchema
    //
    // Lo schema che il modello rispetta in decoding vincolato: il JSON
    // esce sintatticamente valido per costruzione, escape LaTeX compresi.
    // Prima la sintassi era solo "sperata" e a valle serviva una torre
    // di riparazioni (protect/sanitize/repair/rewrap), che resta come
    // rete di sicurezza — e come unico paracadute per Apple locale, che
    // uno schema non ce l'ha. Claude invece lo rispetta: `AIService` lo
    // traduce in JSON Schema e lo passa in `output_config.format` (era
    // ignorato in silenzio fino al 2026-08-17).
    //
    // `required` tiene il minimo indispensabile, in coerenza con i DTO:
    // meglio un esercizio senza "quote" che un modulo fallito perché il
    // modello non trovava una citazione da mettere.

    private static func stringField() -> [String: Any] { ["type": "STRING"] }

    private static func boolField() -> [String: Any] { ["type": "BOOLEAN"] }

    private static func arrayField(of items: [String: Any]) -> [String: Any] {
        ["type": "ARRAY", "items": items]
    }

    private static func objectField(_ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "OBJECT", "properties": properties, "required": required]
    }

    private static func responseSchema(for kind: StudyModuleKind) -> [String: Any] {
        switch kind {
        case .summary:
            return objectField([
                "sections": arrayField(of: objectField([
                    "title": stringField(), "body": stringField(),
                    "quote": stringField(), "source": stringField()
                ], required: ["title", "body"]))
            ], required: ["sections"])
        case .exercises:
            return exercisesSchema
        case .reviewPoints:
            return objectField([
                "points": arrayField(of: objectField([
                    "statement": stringField(), "question": stringField(), "answer": stringField(),
                    "quote": stringField(), "source": stringField(), "topic": stringField()
                ], required: ["statement", "question", "answer"]))
            ], required: ["points"])
        case .flashcards:
            return objectField([
                "cards": arrayField(of: objectField([
                    "front": stringField(), "back": stringField(),
                    "quote": stringField(), "source": stringField()
                ], required: ["front", "back"]))
            ], required: ["cards"])
        }
    }

    // Condiviso tra il modulo esercizi e la rigenerazione del singolo.
    private static var exercisesSchema: [String: Any] {
        objectField([
            "exercises": arrayField(of: objectField([
                // NIENTE "category": gli esercizi sono tutti pratici (si
                // risolvono facendo qualcosa) e la parte concettuale sta
                // nei punti di ripasso. Il campo c'era, significava la
                // PROVENIENZA — "practical" = ispirato ai temi d'esame,
                // "theoretical" = nato dalla teoria — ma veniva letto come
                // se dicesse la natura del compito, e il modello lo
                // assegnava per far quadrare le quote richieste. Tre
                // significati su un'etichetta sola: meglio nessuna.
                "difficulty": stringField(), "topic": stringField(),
                "prompt": stringField(), "steps": arrayField(of: stringField()),
                "answer": stringField(), "source": stringField(), "quote": stringField(),
                "checkExpression": stringField(), "origin": stringField(),
                // "figuraServe" è tra i REQUIRED: qui l'obbligo non è una
                // raccomandazione nel prompt ma un vincolo dello schema,
                // che il provider fa rispettare. È la differenza fra
                // sperare che il modello si ponga la domanda e costringerlo
                // a rispondere. La figura in sé resta facoltativa: obbligata
                // è la DECISIONE, non il disegno.
                "figuraServe": boolField(),
                "figureTikZ": stringField()
            ], required: ["prompt", "answer", "figuraServe"]))
        ], required: ["exercises"])
    }

    private static var verdictsSchema: [String: Any] {
        objectField([
            "verdicts": arrayField(of: [
                "type": "OBJECT",
                "properties": [
                    "index": ["type": "INTEGER"],
                    "risultato": stringField(),
                    "correct": boolField(),
                    "difficolta": ["type": "STRING", "enum": ["base", "medio", "avanzato"]]
                ],
                // L'ORDINE DEI CAMPI È IL MECCANISMO, non un dettaglio.
                // Un booleano "correct" da solo costa zero ragionamento:
                // `true` è la risposta di default di un modello
                // accondiscendente, e infatti passavano esercizi
                // irrecuperabili. Obbligandolo a scrivere PRIMA il
                // risultato suo, il giudizio che segue è il confronto fra
                // due numeri invece che un'impressione. Senza
                // propertyOrdering l'ordine di generazione è arbitrario e
                // il trucco non funziona.
                "propertyOrdering": ["index", "risultato", "correct", "difficolta"],
                "required": ["index", "risultato", "correct", "difficolta"]
            ])
        ], required: ["verdicts"])
    }

    // Senza dire COSA SIGNIFICANO, i tre livelli restano tre parole e il
    // modello produce tre volte lo stesso esercizio introduttivo. La
    // definizione è volutamente indipendente dalla materia, e la riga che
    // conta è l'ultima: avanzato non vuol dire più conti, vuol dire più
    // decisioni. La usano DUE prompt — chi genera e chi corregge — e devono
    // usare la stessa, altrimenti il voto sulla difficoltà misura un metro
    // diverso da quello con cui l'esercizio è stato scritto.
    static let difficultyMeaning = """
    Cosa significano i livelli, in qualunque materia:
    - "base": un passaggio solo, applicazione diretta di una definizione o di una formula.
    - "medio": due o tre passaggi concatenati, dove il risultato di uno entra nel successivo.
    - "avanzato": bisogna COMBINARE due concetti diversi del corso, oppure riconoscere un caso limite o una condizione da verificare PRIMA di poter applicare il metodo, oppure ricavare un dato mancante prima di partire.
    "Avanzato" non vuol dire conti più lunghi: vuol dire più DECISIONI da prendere. Un esercizio con numeri brutti e un solo passaggio resta "base".
    """

    private static func buildPrompt(for kind: StudyModuleKind, from sources: [ResolvedSource], options: StudyModuleOptions, indexTopics: [String] = []) -> String {
        let common = commonPreamble(from: sources)
        switch kind {
        case .summary:
            // Il modello di riferimento sono le "Smart Notes" di
            // Notability: appunti RIELABORATI da cui si studia, non un
            // sommario che elenca cosa c'è. La differenza la fanno la
            // spiegazione in parole semplici dopo ogni definizione e la
            // gerarchia visiva (grassetti, elenchi, formule a display).
            return common + """
            Compito: trasforma i materiali di teoria in APPUNTI RIELABORATI completi, da cui si possa studiare senza aprire i materiali originali. NON un sommario che dice di cosa parlano: una spiegazione vera e propria.

            Struttura: una sezione per ARGOMENTO (non per materiale), nell'ordine logico in cui gli argomenti si costruiscono l'uno sull'altro. Meglio tante sezioni focalizzate che poche generiche.

            Dentro ogni "body", in Markdown:
            - Le DEFINIZIONI e gli enunciati formali per primi, completi e precisi: se il materiale li numera (es. "DEF 1.3", "Proposizione 11.7") conserva la numerazione; il termine definito va in **grassetto**; le condizioni come elenco puntato; le formule in $$ su riga propria.
            - SUBITO DOPO ogni definizione o teorema, la spiegazione in parole semplici: cosa significa e a che cosa serve (es. "La misura 'trasforma' insiemi in numeri, fornendo una dimensione o quantità").
            - Le conseguenze e le osservazioni come punti dedicati che iniziano con "**Conseguenza**:" o "**Osservazione**:".
            - Un esempio concreto quando il materiale lo contiene, introdotto da "**Esempio**:".
            - I passaggi chiave delle dimostrazioni solo se il materiale li riporta, condensati nei 2-3 punti essenziali.
            Schema: {"sections":[{"title":"...","body":"...","quote":"...","source":"..."}]}
            """
        case .exercises:
            let difficultyRule = options.difficulty.map { "Tutti gli esercizi devono avere difficoltà \"\($0.rawValue)\"." }
                ?? "Varia la difficoltà tra base, medio e avanzato, e fai in modo che gli \"avanzato\" siano davvero tali."
            // Con l'indice del Vault gli argomenti sono GIÀ noti: la
            // FASE 1 parte da lì invece di riscoprirli sui soli
            // materiali selezionati — è così che la copertura resta
            // quella del corso intero anche quando nel prompt entra una
            // selezione.
            let phase1 = indexTopics.isEmpty
                ? """
                FASE 1 — Individua da solo TUTTI gli argomenti distinti trattati nei materiali (es. "dualità in PL", "analisi di sensitività", "problema di trasporto"). Argomenti diversi tra loro, non sfumature dello stesso. Non scegliere tu quanti: elencali tutti.
                """
                : """
                FASE 1 — Gli argomenti da coprire sono GIÀ DECISI, questi e soltanto questi:
                \(indexTopics.map { "- \($0)" }.joined(separator: "\n"))
                Non aggiungerne altri e non generare esercizi su argomenti fuori da questo elenco, anche se li vedi nei materiali.
                VINCOLO SUL CAMPO "topic": deve essere COPIATO ALLA LETTERA da questo elenco, identico carattere per carattere. Non riformularlo, non abbreviarlo, non tradurlo, non cambiare maiuscole: le statistiche dei progressi raggruppano su quella stringa esatta e una variante la spezza in due.
                """
            return common + """
            Compito, in due fasi.

            \(phase1)

            FASE 2 — Per OGNI argomento individuato genera \(options.exerciseCount) esercizi. Il campo "topic" contiene l'argomento.

            COSA CONTA COME ESERCIZIO, e qui non ci sono eccezioni: una richiesta che si chiude con un RISULTATO — un numero, un'espressione, una soluzione, una scelta che per essere presa richiede un conto. Chi legge deve dover FARE qualcosa per rispondere.
            Se per rispondere basta enunciare, definire, elencare o spiegare, NON è un esercizio e qui non va: quella è materia da ripasso teorico, che questo studio tratta altrove. Nel dubbio, il test è uno: la risposta è qualcosa che si calcola, o qualcosa che si racconta? Se si racconta, scarta la traccia e scrivine un'altra.

            Se due esercizi finiscono sullo stesso argomento devono affrontarlo da angoli DIVERSI (dato incognito diverso, verso opposto, caso limite), mai essere la stessa traccia con altri numeri.
            TETTO: se argomenti × esercizi supererebbe 15 esercizi totali, riduci il numero per argomento — ma copri comunque OGNI argomento almeno una volta. La copertura viene prima della profondità.
            \(difficultyRule)

            \(Self.difficultyMeaning)

            FORMA DELLA TRACCIA — è la cosa più importante. Una traccia deve presentare da sé tutto il problema, come farebbe un libro di esercizi. Esempio di come DEVE essere:
            "Si consideri il vettore aleatorio gaussiano X con matrice di covarianza $$C_X = \\begin{pmatrix} 8 & 1 & 1 \\\\ 1 & 4 & 1 \\\\ 1 & 1 & 2 \\end{pmatrix}$$ Verificare se X è un vettore aleatorio continuo calcolando il determinante di $$C_X$$."
            Esempi di come NON deve essere: "Qual è la proprietà dimostrata nell'esercizio 3?", "Risolvi il punto b) del tema del 2019", "Si consideri la matrice dell'esempio precedente".
            Autosufficiente non vuol dire inventato a caso: i dati devono essere plausibili e coerenti con la teoria dei materiali, e la soluzione deve tornare davvero.

            REGOLA FONDAMENTALE — gli esercizi devono essere AUTOSUFFICIENTI:
            - Chi legge la traccia deve poterla risolvere SENZA avere davanti i materiali o il tema d'esame. Riporta nella traccia tutti i dati, le funzioni, i valori e le ipotesi che servono.
            - È VIETATO rimandare alla fonte: mai "come nell'esercizio 3 del tema del 2019", "risolvi l'esercizio del compito", "si consideri la funzione dell'esempio precedente". Se copi la traccia di un tema d'esame parola per parola non stai aiutando: quello lo studente può già farlo da solo.
            - Gli esercizi vanno INVENTATI ISPIRANDOSI ai temi d'esame: stessa tipologia, stessa struttura di richiesta, stesso livello di difficoltà e stesso tipo di conti, ma con dati, numeri, funzioni e contesto DIVERSI. Devono sembrare usciti dallo stesso esame, senza esserne la copia.
            - I materiali di TEORIA vanno letti eccome: è lì che stanno il metodo, le condizioni di applicabilità e le convenzioni della materia, e un esercizio che le contraddice è sbagliato anche se i conti tornano. Servono a impostare il problema, non a fornire la traccia.
            - Se fra i materiali non ci sono temi d'esame, prendi la forma dagli ESEMPI SVOLTI nella teoria: la mancanza di temi non è un motivo per non generare esercizi.

            Ricorda le regole di formattazione: le funzioni, le espressioni e i risultati con esponenti o frazioni vanno in LaTeX tra $$ su riga propria, sia nella traccia sia nei passi sia nella risposta.

            Ogni esercizio ha una soluzione guidata in 3-5 passi concreti e una risposta finale; "topic" è l'argomento in 2-4 parole; "source" è il titolo del materiale a cui ti sei ispirato e "quote" il passaggio originale (servono solo alla tracciabilità, NON vanno citati nella traccia).
            Indica "origin": "invented" se hai scritto tu la traccia ispirandoti ai materiali (è il caso normale), "fromMaterials" solo se la traccia è già presente come tale nei materiali e l'hai riportata.
            FIGURA — decisione OBBLIGATORIA. Per ogni esercizio devi indicare "figuraServe": true oppure false. Non omettere mai questo campo.
            Il criterio non è estetico ma operativo: la figura serve quando la traccia contiene informazione che di per sé NON è lineare, e il testo si limita a trascriverla — relazioni fra entità, disposizioni nello spazio, andamento di una grandezza. Il segnale più affidabile è questo: se per risolvere l'esercizio lo studente dovrebbe prima ricostruirsi un disegno partendo dal testo, allora quel disegno deve stare nella traccia.
            Caso da non mancare: se la traccia elenca legami fra entità — "A collegato a B con valore 5", una transizione fra due stati, un vincolo fra due elementi — quell'elenco È già un disegno scritto a parole, e va disegnato.
            La figura NON serve quando la traccia è già completa in forma simbolica o discorsiva e il disegno sarebbe solo decorazione: manipolazioni algebriche, dimostrazioni, calcoli su valori già dati, definizioni. E non sono figure: una tabella di dati, un elenco riscritto dentro riquadri, un enunciato messo in cornice.
            Gli esempi qui sopra sono illustrativi, NON un elenco chiuso di argomenti: applica il criterio alla traccia che hai davanti, qualunque sia la materia.
            Se "figuraServe" è true, allora "figureTikZ" è OBBLIGATORIO: solo il codice dell'ambiente, da \\begin{tikzpicture} a \\end{tikzpicture} (eventuali \\usetikzlibrary sulle righe precedenti). I dati della figura devono coincidere ESATTAMENTE con quelli della traccia (stessi valori, stesse entità, stessa funzione).
            Librerie disponibili: pgfplots (\\begin{axis} per le funzioni), automata, positioning, arrows.meta, matrix, calc, shapes. NON sono disponibili circuitikz né tikz-cd.
            Se il disegno che servirebbe richiede strumenti non disponibili, metti "figuraServe": false — meglio nessuna figura che una figura sbagliata.
            Includi "checkExpression" SOLO quando la risposta è un valore matematico verificabile in modo indipendente: mettici l'espressione da calcolare in sintassi Wolfram Alpha, il cui risultato deve coincidere con "answer". Omettilo per gli esercizi discorsivi.
            IMPORTANTE su checkExpression: dev'essere una FORMULA o una grandezza, non la descrizione di un compito. Wolfram accetta "integrate x^2 from 0 to 1", "eigenvalues {{2,1},{1,2}}", "roots of s^2+3s+2", "10*2000/(1000+2000)", "bode plot 1/(s+1)"; RIFIUTA fraseggi come "step response 1/(s^2+2s+1)", "voltage divider 10V 1kohm 2kohm", "beam deflection cantilever", "is G(s) stable". Se il calcolo è ingegneristico, scrivilo come espressione numerica esplicita con i valori già sostituiti.
            Schema: {"exercises":[{"difficulty":"base|medio|avanzato","topic":"...","prompt":"...","steps":["...","..."],"answer":"...","source":"...","quote":"...","checkExpression":"...","origin":"invented|fromMaterials","figuraServe":true,"figureTikZ":"..."}]}
            """
        case .reviewPoints:
            // L'argomento serve all'ANALISI: è la chiave con cui teoria e
            // pratica finiscono nella stessa riga. Col vocabolario del
            // Vault va copiato alla lettera, per la stessa ragione per cui
            // lo si impone agli esercizi — una variante spezza in due le
            // statistiche dello stesso argomento.
            let reviewTopicRule = indexTopics.isEmpty
                ? """
                ARGOMENTO: ogni domanda porta il campo "topic", l'argomento in 2-4 parole (es. "dualità in PL", "analisi di sensitività"). Serve a incrociare queste domande con gli esercizi da risolvere sullo stesso argomento.
                """
                : """
                ARGOMENTO: ogni domanda porta il campo "topic", COPIATO ALLA LETTERA da questo elenco, identico carattere per carattere — non riformularlo, non abbreviarlo, non cambiare maiuscole:
                \(indexTopics.map { "- \($0)" }.joined(separator: "\n"))
                Se una domanda non ricade in nessuno di questi argomenti, non farla.
                """
            return common + """
            Compito: scrivi 5-10 ESERCIZI TEORICI sui materiali di teoria. Per ognuno: l'enunciato del concetto su cui verte (statement), la domanda (question) e la risposta corretta (answer).

            COSA DEVE CHIEDERE LA DOMANDA. Non "che cos'è X" e non "definisci X": quello è richiamo a memoria, e in questo studio lo fanno le flashcard. Qui la domanda deve costringere a RAGIONARE su qualcosa che si è già letto:
            - sotto quali ipotesi vale un risultato, e che cosa succede se cade l'ipotesi;
            - quando un metodo si applica e quando NON si applica, e perché;
            - la differenza fra due nozioni vicine che si confondono facilmente;
            - perché un passaggio di una dimostrazione è necessario, o cosa andrebbe storto senza;
            - se un'affermazione è vera o falsa, con la giustificazione.
            Una domanda a cui si può rispondere ripetendo una frase dei materiali è una domanda sbagliata: riscrivila.

            VINCOLO SULLA FONTE: la risposta deve essere sostenuta da quello che c'è scritto NEI MATERIALI, non da quello che sai tu della materia. Se per rispondere devi aggiungere un risultato che lì non c'è, cambia domanda. In "quote" va il passaggio originale che la sostiene.

            \(reviewTopicRule)
            Schema: {"points":[{"statement":"...","question":"...","answer":"...","quote":"...","source":"..."}]}
            """
        case .flashcards:
            return common + """
            Compito: crea 8-15 flashcard domanda/risposta dai materiali di teoria. Fronte breve e specifico, retro con la risposta basata sui materiali.
            Schema: {"cards":[{"front":"...","back":"...","quote":"...","source":"..."}]}
            """
        }
    }

    // DTO per il parsing delle risposte del modello: come i payload ma
    // senza id (il modello non deve generarli, li mettiamo noi al mapping).
    // Elemento di un array che può fallire da solo senza portarsi dietro
    // tutti gli altri. Senza questo, un singolo esercizio a cui il
    // modello ha dimenticato "steps" fa fallire la decodifica dell'INTERO
    // set — otto esercizi buttati per colpa di uno. Codable di serie non
    // perdona: una chiave mancante è un errore, non un default.
    private struct Failable<Wrapped: Decodable>: Decodable {
        let value: Wrapped?
        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(Wrapped.self)
        }
    }

    private struct AISummaryDTO: Decodable, ArrayWrapped {
        static let arrayKey = "sections"
        struct Section: Decodable { var title: String; var body: String; var quote: String?; var source: String? }
        var sectionItems: [Failable<Section>]
        var sections: [Section] { sectionItems.compactMap(\.value) }
        enum CodingKeys: String, CodingKey { case sectionItems = "sections" }
    }

    private struct AIExercisesDTO: Decodable, ArrayWrapped {
        static let arrayKey = "exercises"
        struct Item: Decodable {
            var difficulty: String?
            var topic: String?
            var prompt: String
            // Un esercizio senza passaggi guidati è comunque un esercizio:
            // meglio mostrarlo con la sola risposta che scartarlo.
            var stepList: [String]?
            var steps: [String] { stepList ?? [] }
            var answer: String
            var source: String?
            var quote: String?
            var checkExpression: String?
            var origin: String?
            // OPZIONALE anche se il prompt lo dichiara obbligatorio:
            // l'obbligo vive nel prompt, mai nello schema. Con la
            // decodifica per-elemento, un campo davvero obbligatorio e
            // mancante farebbe sparire l'INTERO esercizio invece della
            // sola figura.
            var figuraServe: Bool?
            var figureTikZ: String?

            enum CodingKeys: String, CodingKey {
                case difficulty, topic, prompt, answer, source, quote, checkExpression, origin, figuraServe, figureTikZ
                case stepList = "steps"
            }
        }
        var exerciseItems: [Failable<Item>]
        var exercises: [Item] { exerciseItems.compactMap(\.value) }
        enum CodingKeys: String, CodingKey { case exerciseItems = "exercises" }
    }

    private struct AIReviewPointsDTO: Decodable, ArrayWrapped {
        static let arrayKey = "points"
        struct Point: Decodable { var statement: String; var question: String; var answer: String; var quote: String?; var source: String?; var topic: String? }
        var pointItems: [Failable<Point>]
        var points: [Point] { pointItems.compactMap(\.value) }
        enum CodingKeys: String, CodingKey { case pointItems = "points" }
    }

    private struct AIFlashcardsDTO: Decodable, ArrayWrapped {
        static let arrayKey = "cards"
        struct Card: Decodable { var front: String; var back: String; var quote: String?; var source: String? }
        var cardItems: [Failable<Card>]
        var cards: [Card] { cardItems.compactMap(\.value) }
        enum CodingKeys: String, CodingKey { case cardItems = "cards" }
    }

    // Decodifica in tre tentativi, dal più probabile al più disperato:
    // il JSON così com'è, poi la sua riparazione se era troncato a metà,
    // e infine — se non c'è niente da salvare — l'errore VERO invece di
    // "non conforme allo schema", che non diceva a nessuno cosa fosse
    // andato storto.
    // `Result` vorrebbe un tipo conforme a Error come fallimento, e qui
    // il fallimento è già un messaggio pronto per l'utente.
    private enum DecodeResult<T> {
        case success(T)
        case failure(String)
    }

    private static func decodeDTO<T: Decodable>(_ type: T.Type, from json: String) -> DecodeResult<T> {
        let decoder = JSONDecoder()
        guard let data = json.data(using: .utf8) else {
            return .failure("La risposta del modello non è testo valido.")
        }
        // Va applicata SEMPRE, non come ripiego: i comandi LaTeX che
        // iniziano con b/f/n/r/t decodificano senza errori, solo corrotti.
        // Aspettare il fallimento non li salverebbe mai.
        let protected = AIService.protectLaTeXEscapes(in: json)
        if let protectedData = protected.data(using: .utf8),
           let dto = try? decoder.decode(type, from: protectedData) {
            return .success(dto)
        }

        do {
            return .success(try decoder.decode(type, from: data))
        } catch let firstError {
            // Tentativo 2: backslash LaTeX non validi come escape JSON.
            let sanitized = AIService.sanitizeJSONEscapes(in: protected)
            if let sanitizedData = sanitized.data(using: .utf8),
               let dto = try? decoder.decode(type, from: sanitizedData) {
                return .success(dto)
            }
            // Tentativo 3: risposta interrotta a metà — si salva quello
            // che è arrivato completo. Si parte dal testo già ripulito,
            // perché i due guasti capitano volentieri insieme.
            if let repaired = AIService.repairTruncatedJSON(from: sanitized),
               let repairedData = repaired.data(using: .utf8),
               let dto = try? decoder.decode(type, from: repairedData) {
                return .success(dto)
            }
            // Tentativo 4: il contenuto c'è ma è impacchettato diversamente
            // — l'array nudo senza oggetto attorno, o sotto un nome che il
            // modello si è inventato ("esercizi", "items", "data"). Gli
            // elementi sono giusti: buttare via tutto per il nome del
            // contenitore è lo spreco più stupido possibile.
            if let key = (type as? ArrayWrapped.Type)?.arrayKey {
                for candidate in [json, sanitized] {
                    guard let rewrapped = rewrapArray(in: candidate, under: key),
                          let dto = try? decoder.decode(type, from: rewrapped) else { continue }
                    return .success(dto)
                }
            }
            return .failure(describe(firstError))
        }
    }

    // Ricostruisce l'oggetto che il decoder si aspetta attorno all'array
    // trovato: array nudo → {chiave: [...]}, oppure oggetto con l'array
    // sotto un altro nome → stesso array, nome giusto. Se di array ce n'è
    // più d'uno si prende il più lungo, che è il contenuto vero.
    private static func rewrapArray(in json: String, under key: String) -> Data? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        var array: [Any]?
        if let bare = root as? [Any] {
            array = bare
        } else if let object = root as? [String: Any] {
            // Se la chiave giusta c'è già, rimpacchettare non serve a nulla.
            guard object[key] == nil else { return nil }
            array = object.values.compactMap { $0 as? [Any] }.max { $0.count < $1.count }
        }
        guard let array, !array.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: [key: array])
    }

    private static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return "Il modello ha restituito un JSON illeggibile: \(error.localizedDescription)"
        }
        switch decodingError {
        case .keyNotFound(let key, _):
            return "Il modello ha omesso il campo obbligatorio \"\(key.stringValue)\"."
        case .typeMismatch(let type, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "Il modello ha usato un tipo sbagliato (atteso \(type)) in \"\(path)\"."
        case .valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return "Il modello ha lasciato vuoto il campo \"\(path)\"."
        case .dataCorrupted:
            // ERA "la risposta si è interrotta prima della fine", e per
            // molto tempo era vero: una risposta tagliata da MAX_TOKENS
            // arrivava fin qui e moriva nel decoder. Da quando il
            // troncamento ha una strada sua (recupero degli elementi
            // completi, e in mancanza un errore che lo dice), qui resta il
            // JSON semplicemente NON VALIDO — su Gemini quasi impossibile
            // con lo schema attivo, plausibile su Claude e sul modello
            // locale, che schema non hanno. Chiamarlo ancora
            // "interruzione" manderebbe a cercare la causa sbagliata.
            return "Il modello ha risposto con un JSON non valido, e non c'era nessun elemento completo da salvare. Riprova, oppure chiedi meno contenuti per volta."
        @unknown default:
            return "Il modello ha restituito un JSON non conforme."
        }
    }

    // MARK: - Figura mancante
    //
    // Due rilevatori di forza molto diversa, entrambi programmatici: non
    // si chiede a un modello di giudicare il lavoro di un altro modello.
    //
    // 1. ESATTO, zero falsi positivi: il modello ha dichiarato
    //    "figuraServe": true e poi non ha scritto la figura. Non stiamo
    //    interpretando la traccia — è lui che si è contraddetto.
    // 2. EURISTICO: la decisione manca (o è false) su una traccia che ha
    //    la FORMA di un elenco di relazioni. Volutamente strutturale e
    //    non lessicale: un elenco di parole chiave ("grafo", "nodi")
    //    coprirebbe solo le materie a cui abbiamo pensato noi, mentre la
    //    forma prende allo stesso modo cammini minimi, catene di Markov,
    //    reti di precedenze e sistemi di vincoli.
    //
    // Restituisce nil quando non c'è niente da segnalare, così il campo
    // resta assente nella stragrande maggioranza degli esercizi.
    private static func figureIsMissing(declared: Bool?, tikz: String?, prompt: String) -> Bool? {
        let hasFigure = !(tikz ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !hasFigure else { return nil }
        if declared == true { return true }
        return looksRelational(prompt) ? true : nil
    }

    // Almeno tre RIGHE che contengono una coppia fra parentesi: è la
    // firma di un elenco di legami ("(1,2) con costo 5"). Si contano le
    // righe e non le occorrenze perché un singolo intervallo come
    // $(0,1)$ dentro un testo discorsivo non deve far scattare niente,
    // mentre un elenco puntato di relazioni sì.
    private static func looksRelational(_ prompt: String) -> Bool {
        guard let pair = try? Regex(#"\([^()\n]{1,24},[^()\n]{1,24}\)"#) else { return false }
        let linesWithPair = prompt
            .split(separator: "\n")
            .filter { $0.firstMatch(of: pair) != nil }
        return linesWithPair.count >= 3
    }

    // MARK: - Verifica programmatica delle citazioni
    //
    // Questo è l'unico controllo del sistema che NON dipende dal giudizio
    // di un modello: si cerca la citazione dichiarata dentro il testo dei
    // materiali. Se non c'è, il modello ha scritto un passaggio che non ha
    // mai letto, e il contenuto va mostrato con riserva. Il confronto
    // normalizza spazi, maiuscole e apostrofi/virgolette tipografiche,
    // perché i modelli riformattano la punteggiatura anche quando citano
    // fedelmente.
    private static func normalizedForMatching(_ text: String) -> String {
        var result = text.lowercased()
        let replacements = ["’": "'", "‘": "'", "“": "\"", "”": "\"", "–": "-", "—": "-", "\n": " ", "\t": " "]
        for (from, to) in replacements {
            result = result.replacingOccurrences(of: from, with: to)
        }
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Secondo tentativo di confronto, per le citazioni che il modello ha
    // "abbellito" nonostante il divieto: toglie i SOLI segni di
    // formattazione ($$, $, **, backtick, \( \[ ...) e tutti gli spazi.
    //
    // Non allenta la verifica, che è il cuore della difesa contro le
    // allucinazioni: una parafrasi continua a non corrispondere. Toglie
    // solo decorazioni aggiunte sopra il testo e le spaziature strane che
    // l'estrazione da PDF produce a caso.
    private static func strippedForMatching(_ text: String) -> String {
        var result = normalizedForMatching(text)
        for marker in ["$$", "$", "**", "__", "`", "\\(", "\\)", "\\[", "\\]"] {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        return result.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    // Ricontrolla le citazioni già salvate di uno studio.
    //
    // L'esito della verifica viene scritto una volta sola, al momento
    // della generazione: un contenuto marcato "non verificato" da un
    // confronto troppo severo resterebbe tale per sempre, anche dopo che
    // il confronto è stato corretto. Qui si rifà il controllo sul
    // contenuto già in archivio.
    //
    // Lavora sul JSON grezzo invece che sui tipi: ogni modulo ha un
    // contenuto diverso (riassunto, esercizi, punti di ripasso...) ma le
    // citazioni hanno tutte la stessa forma, e così ne resta fuori
    // nessuna — comprese quelle dei tipi che verranno.
    @discardableResult
    static func reverifyCitations(in study: Study) -> Int {
        let sources = study.materials.compactMap { material -> ResolvedSource? in
            let text = material.extractedText
            guard !text.isEmpty else { return nil }
            return ResolvedSource(title: material.title, text: text, isExamPaper: material.isExamPaper)
        }
        guard !sources.isEmpty else { return 0 }

        var changed = 0
        for module in study.modules {
            guard let data = module.contentJSON.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) else { continue }
            let updated = revisit(root, in: sources, changed: &changed)
            guard changed > 0,
                  let newData = try? JSONSerialization.data(withJSONObject: updated),
                  let json = String(data: newData, encoding: .utf8) else { continue }
            module.contentJSON = json
        }
        return changed
    }

    // Scende ricorsivamente nel JSON e ricalcola "verified" ovunque trovi
    // la coppia che identifica una citazione.
    private static func revisit(_ node: Any, in sources: [ResolvedSource], changed: inout Int) -> Any {
        if var object = node as? [String: Any] {
            if let text = object["text"] as? String, object["verified"] is Bool {
                let verified = makeCitation(quote: text, source: nil, in: sources)?.verified ?? false
                if object["verified"] as? Bool != verified {
                    object["verified"] = verified
                    changed += 1
                }
            }
            for (key, value) in object {
                object[key] = revisit(value, in: sources, changed: &changed)
            }
            return object
        }
        if let array = node as? [Any] {
            return array.map { revisit($0, in: sources, changed: &changed) }
        }
        return node
    }

    private static func makeCitation(quote: String?, source: String?, in sources: [ResolvedSource]) -> SourceCitation? {
        guard let quote, quote.count >= 12 else { return nil }
        let needle = normalizedForMatching(quote)
        var verified = sources.contains { normalizedForMatching($0.text).contains(needle) }
        if !verified {
            let strippedNeedle = strippedForMatching(quote)
            // La soglia sui caratteri va ricontrollata dopo lo spoglio:
            // una "citazione" fatta quasi solo di simboli si ridurrebbe a
            // un pugno di caratteri, che si ritrovano ovunque.
            if strippedNeedle.count >= 12 {
                verified = sources.contains { strippedForMatching($0.text).contains(strippedNeedle) }
            }
        }
        return SourceCitation(text: quote, sourceTitle: source, verified: verified)
    }

}
