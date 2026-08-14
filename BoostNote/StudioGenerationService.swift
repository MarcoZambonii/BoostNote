import Foundation
import SwiftData

// I DTO che sono "un array dentro un oggetto" dichiarano qui quale sia
// quella chiave, così la decodifica può rimpacchettare una risposta
// arrivata con un contenitore diverso. Sta a livello di file perché in
// Swift un protocollo non si può annidare dentro un tipo.
private protocol ArrayWrapped { static var arrayKey: String { get } }

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
        let jobs: [(index: Int, kind: StudyModuleKind, options: StudyModuleOptions)] =
            pending.enumerated().compactMap { offset, module in
                guard let kind = module.kind else { return nil }
                return (offset, kind, module.options)
            }

        let outcomes = await withTaskGroup(of: (Int, GenerationOutcome).self) { group -> [Int: GenerationOutcome] in
            var results: [Int: GenerationOutcome] = [:]
            var next = 0
            let maxConcurrent = 3

            func addJob(_ job: (index: Int, kind: StudyModuleKind, options: StudyModuleOptions)) {
                group.addTask {
                    (job.index, await generateWithAI(for: job.kind, from: resolved, options: job.options))
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
        let notice = truncationNotice(for: resolved)
        for (offset, module) in pending.enumerated() {
            switch outcomes[offset] {
            case .success(let generated, let discarded):
                module.contentJSON = generated
                module.generatedByRaw = AIService.selectedProvider.label
                // Se gli esercizi sono finiti sul modello di ripiego, va
                // detto: la differenza si vede (domande di definizione
                // invece di esercizi con dati), e senza spiegazione
                // sembrerebbe un peggioramento inspiegabile.
                var warning = notice
                if module.kind == .exercises, AIService.isLiteModel(AIService.lastUsedModelID) {
                    let quotaNote = "Quota dei modelli migliori esaurita per oggi: questi esercizi sono stati generati con il modello veloce e possono essere più semplici. Rigenerali domani per averli migliori."
                    warning = [notice, quotaNote].compactMap { $0 }.joined(separator: " ")
                }
                module.generationError = warning
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
    // piccoli (un modulo per chiamata) e temperatura bassa (in AIService).
    // Doppio passaggio "correttore" e sourceRange/citazioni puntuali:
    // ancora da aggiungere quando arriva l'estrazione testo dai PDF.

    // Esito della generazione reale: contenuto pronto o motivo del fallimento
    // (una String, non un Error: finisce dritta in UI).
    private enum GenerationOutcome {
        case success(String, discarded: Int)
        case failure(String)
    }

    private static func generateWithAI(for kind: StudyModuleKind, from sources: [ResolvedSource], options: StudyModuleOptions) async -> GenerationOutcome {
        // Un modello sotto carico ogni tanto risponde ma DEGRADATO: JSON
        // con la forma sbagliata ("il modello ha omesso il campo
        // sections" — successo davvero, sotto un 503 diffuso). Buttare
        // via il modulo per una risposta storta costa più del secondo
        // tentativo, che si paga solo in questo caso raro.
        var lastFailure: GenerationOutcome = .failure("Il modello non ha restituito JSON.")
        for _ in 0...1 {
            switch await generateOnce(for: kind, from: sources, options: options) {
            case .retryable(let outcome):
                lastFailure = outcome
            case .final(let outcome):
                return outcome
            }
        }
        return lastFailure
    }

    // Distingue i fallimenti che un secondo tentativo può sistemare
    // (risposta malformata: il modello ritenta e di solito la scrive
    // giusta) da quelli su cui insistere è inutile o dannoso (niente
    // quota, niente rete: si sprecherebbe un'altra chiamata).
    private enum AttemptResult {
        case final(GenerationOutcome)
        case retryable(GenerationOutcome)
    }

    private static func generateOnce(for kind: StudyModuleKind, from sources: [ResolvedSource], options: StudyModuleOptions) async -> AttemptResult {
        let prompt = buildPrompt(for: kind, from: sources, options: options)
        let raw: String
        // Gli esercizi passano dal modello capace, gli altri moduli no.
        // Misurato sullo stesso prompt: il Lite produce domande di
        // definizione ("scrivi il duale di min c'x"), il Flash esercizi
        // con dati concreti da applicare ("ottimo finito 15, quanto vale
        // il duale?"). Su riassunti, flashcard e punti di ripasso — che
        // sono compiti estrattivi — la differenza non si vede, e lì il
        // Lite è sei volte più veloce.
        switch await AIService.generate(prompt: prompt, tier: kind == .exercises ? .full : .lite) {
        case .failure(let error):
            return .final(.failure(error.message))
        case .success(let text):
            raw = text
        }
        switch await parse(raw, for: kind, from: sources, options: options) {
        case .success(let outcome):
            return .final(outcome)
        case .failure(let message):
            return .retryable(.failure(message))
        }
    }

    private enum ParseResult {
        case success(GenerationOutcome)
        case failure(String)
    }

    private static func parse(_ raw: String, for kind: StudyModuleKind, from sources: [ResolvedSource], options: StudyModuleOptions) async -> ParseResult {
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
            })))
        case .exercises:
            let dto: AIExercisesDTO
            switch decodeDTO(AIExercisesDTO.self, from: json) {
            case .failure(let message): return .failure(message)
            case .success(let decoded): dto = decoded
            }
            guard !dto.exercises.isEmpty else { return .failure(emptyError) }
            var exercises = dto.exercises.map { item in
                StudyExercise(
                    categoryRaw: (ExerciseCategory(rawValue: item.category ?? "") ?? .theoretical).rawValue,
                    difficultyRaw: (ExerciseDifficulty(rawValue: item.difficulty ?? "") ?? .base).rawValue,
                    topic: item.topic ?? "Senza argomento",
                    prompt: item.prompt,
                    steps: item.steps,
                    answer: item.answer,
                    sourceTitle: item.source,
                    quote: makeCitation(quote: item.quote, source: item.source, in: sources),
                    checkExpression: item.checkExpression,
                    verificationRaw: ExerciseVerification.notChecked.rawValue,
                    originRaw: (ExerciseOrigin(rawValue: item.origin ?? "") ?? .invented).rawValue
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
                        let agreed = verdicts[index] ?? true
                        if agreed {
                            exercise.verificationRaw = ExerciseVerification.agreed.rawValue
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
            return .success(encodePayload(ExerciseSetContent(exercises: exercises), discarded: discarded))
        case .reviewPoints:
            let dto: AIReviewPointsDTO
            switch decodeDTO(AIReviewPointsDTO.self, from: json) {
            case .failure(let message): return .failure(message)
            case .success(let decoded): dto = decoded
            }
            guard !dto.points.isEmpty else { return .failure(emptyError) }
            return .success(encodePayload(ReviewPointsContent(points: dto.points.map {
                ReviewPoint(statement: $0.statement, question: $0.question, answer: $0.answer,
                            quote: makeCitation(quote: $0.quote, source: $0.source, in: sources))
            })))
        case .flashcards:
            let dto: AIFlashcardsDTO
            switch decodeDTO(AIFlashcardsDTO.self, from: json) {
            case .failure(let message): return .failure(message)
            case .success(let decoded): dto = decoded
            }
            guard !dto.cards.isEmpty else { return .failure(emptyError) }
            return .success(encodePayload(FlashcardsContent(cards: dto.cards.map {
                Flashcard(front: $0.front, back: $0.back, quote: makeCitation(quote: $0.quote, source: $0.source, in: sources))
            })))
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

        let prompt = """
        \(commonPreamble(from: sources))

        Un esercizio che avevi generato è stato SEGNALATO come sbagliato dallo studente. Riscrivilo da capo correggendo il problema.

        ESERCIZIO DA CORREGGERE:
        Traccia: \(old.prompt)
        Risposta data: \(old.answer)

        COSA NON VA (segnalato dallo studente): \(feedback.isEmpty ? "non specificato: ricontrolla soprattutto la correttezza della soluzione" : feedback)

        Genera UN SOLO esercizio sostitutivo, sullo stesso argomento ("\(old.topic)") e della stessa difficoltà, che non ripeta l'errore segnalato.
        Gli altri esercizi del set coprono già questi argomenti, NON generarne uno su di essi: \(otherTopics.isEmpty ? "nessuno" : otherTopics.joined(separator: ", ")). Valgono tutte le regole di prima: traccia autosufficiente, formule in LaTeX tra $$ su riga propria, citazione verbatim dai materiali.
        Schema: {"exercises":[{"category":"theoretical|practical","difficulty":"base|medio|avanzato","topic":"...","prompt":"...","steps":["..."],"answer":"...","source":"...","quote":"...","checkExpression":"...","origin":"invented|fromMaterials"}]}
        """

        guard case .success(let raw) = await AIService.generate(prompt: prompt),
              let json = AIService.extractJSON(from: raw),
              case .success(let dto) = decodeDTO(AIExercisesDTO.self, from: json),
              let item = dto.exercises.first else {
            return "La rigenerazione non è riuscita. L'esercizio segnalato è rimasto invariato."
        }

        content.exercises[index] = StudyExercise(
            categoryRaw: (ExerciseCategory(rawValue: item.category ?? "") ?? old.category).rawValue,
            difficultyRaw: (ExerciseDifficulty(rawValue: item.difficulty ?? "") ?? old.difficulty).rawValue,
            topic: item.topic ?? old.topic,
            prompt: item.prompt,
            steps: item.steps,
            answer: item.answer,
            sourceTitle: item.source,
            quote: makeCitation(quote: item.quote, source: item.source, in: sources),
            checkExpression: item.checkExpression,
            originRaw: (ExerciseOrigin(rawValue: item.origin ?? "") ?? .invented).rawValue
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
    private static func verifyExercises(_ exercises: [StudyExercise], from sources: [ResolvedSource]) async -> [Int: Bool] {
        guard !exercises.isEmpty else { return [:] }
        var list = ""
        for (index, exercise) in exercises.enumerated() {
            list += "\n[\(index)] TRACCIA: \(exercise.prompt)\nRISPOSTA PROPOSTA: \(exercise.answer)\n"
        }
        let prompt = """
        Sei un correttore severo. Per ogni esercizio qui sotto, risolvilo tu stesso a partire dai materiali e poi giudica se la RISPOSTA PROPOSTA è corretta e coerente con i materiali.
        Sii critico: se la risposta è vaga, non verificabile dai materiali, o matematicamente errata, marcala come NON corretta.
        Rispondi SOLO con JSON valido, senza testo attorno, nel formato: {"verdicts":[{"index":0,"correct":true},{"index":1,"correct":false}]}

        MATERIALI (estratto di contesto):
        \(String(materialsBlock(from: sources).prefix(20000)))

        ESERCIZI DA VERIFICARE:
        \(list)
        """
        guard case .success(let raw) = await AIService.generate(prompt: prompt, tier: .full),
              let json = AIService.extractJSON(from: raw),
              let data = json.data(using: .utf8),
              let dto = try? JSONDecoder().decode(AIVerdictsDTO.self, from: data) else {
            // Verifica non riuscita: non si scarta nulla (meglio un
            // esercizio non verificato che perderlo per un errore nostro).
            return [:]
        }
        var result: [Int: Bool] = [:]
        for verdict in dto.verdicts {
            result[verdict.index] = verdict.correct
        }
        return result
    }

    private struct AIVerdictsDTO: Decodable {
        struct Verdict: Decodable { var index: Int; var correct: Bool }
        var verdicts: [Verdict]
    }

    private static func encodePayload(_ payload: some Encodable, discarded: Int = 0) -> GenerationOutcome {
        guard let data = try? JSONEncoder().encode(payload), let string = String(data: data, encoding: .utf8) else {
            return .failure("Errore interno di codifica del contenuto.")
        }
        return .success(string, discarded: discarded)
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
        - OGNI espressione matematica che contenga esponenti, frazioni, radici, integrali, sommatorie, limiti, derivate o simboli greci va scritta in LaTeX su una RIGA A SÉ, delimitata da $$ sopra e sotto. Vengono rese in vera notazione matematica.
        - NON scrivere MAI notazione a caratteri tipo "x^3 - 3x^2 + 2x", "sqrt(2)", "integrale da 1 a 2": è illeggibile. Scrivi invece, su riga propria:
        $$f(x) = x^3 - 3x^2 + 2x + 1$$
        - Restano testo semplice solo i simboli isolati senza struttura (per esempio "la funzione f", "il punto c", "l'intervallo [1, 2]").
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

    private static func buildPrompt(for kind: StudyModuleKind, from sources: [ResolvedSource], options: StudyModuleOptions) -> String {
        let common = commonPreamble(from: sources)
        switch kind {
        case .summary:
            return common + """
            Compito: riassumi i materiali di teoria, una sezione per materiale (o per argomento se un materiale copre più argomenti).
            Schema: {"sections":[{"title":"...","body":"...","quote":"...","source":"..."}]}
            """
        case .exercises:
            let difficultyRule = options.difficulty.map { "Tutti gli esercizi devono avere difficoltà \"\($0.rawValue)\"." }
                ?? "Varia la difficoltà tra base, medio e avanzato."
            var categoryRule = ""
            if !options.includeTheoretical || options.theoreticalCount == 0 { categoryRule += " Non generare esercizi teorici." }
            if !options.includePractical || options.practicalCount == 0 { categoryRule += " Non generare esercizi pratici." }
            return common + """
            Compito, in due fasi.

            FASE 1 — Individua da solo TUTTI gli argomenti distinti trattati nei materiali (es. "dualità in PL", "analisi di sensitività", "problema di trasporto"). Argomenti diversi tra loro, non sfumature dello stesso. Non scegliere tu quanti: elencali tutti.

            FASE 2 — Per OGNI argomento individuato genera \(options.theoreticalCount) esercizi teorici e \(options.practicalCount) pratici. Il campo "topic" contiene l'argomento.
            Se due esercizi finiscono sullo stesso argomento devono affrontarlo da angoli DIVERSI (dato incognito diverso, verso opposto, caso limite), mai essere la stessa traccia con altri numeri.
            TETTO: se argomenti × esercizi supererebbe 15 esercizi totali, riduci il numero per argomento — ma copri comunque OGNI argomento almeno una volta. La copertura viene prima della profondità.
            \(difficultyRule)\(categoryRule)

            FORMA DELLA TRACCIA — è la cosa più importante. Una traccia deve presentare da sé tutto il problema, come farebbe un libro di esercizi. Esempio di come DEVE essere:
            "Si consideri il vettore aleatorio gaussiano X con matrice di covarianza $$C_X = \\begin{pmatrix} 8 & 1 & 1 \\\\ 1 & 4 & 1 \\\\ 1 & 1 & 2 \\end{pmatrix}$$ Verificare se X è un vettore aleatorio continuo calcolando il determinante di $$C_X$$."
            Esempi di come NON deve essere: "Qual è la proprietà dimostrata nell'esercizio 3?", "Risolvi il punto b) del tema del 2019", "Si consideri la matrice dell'esempio precedente".
            Autosufficiente non vuol dire inventato a caso: i dati devono essere plausibili e coerenti con la teoria dei materiali, e la soluzione deve tornare davvero.

            REGOLA FONDAMENTALE — gli esercizi devono essere AUTOSUFFICIENTI:
            - Chi legge la traccia deve poterla risolvere SENZA avere davanti i materiali o il tema d'esame. Riporta nella traccia tutti i dati, le funzioni, i valori e le ipotesi che servono.
            - È VIETATO rimandare alla fonte: mai "come nell'esercizio 3 del tema del 2019", "risolvi l'esercizio del compito", "si consideri la funzione dell'esempio precedente". Se copi la traccia di un tema d'esame parola per parola non stai aiutando: quello lo studente può già farlo da solo.
            - Gli esercizi "practical" devono essere INVENTATI ISPIRANDOSI ai temi d'esame: stessa tipologia, stessa struttura di richiesta, stesso livello di difficoltà e stesso tipo di conti, ma con dati, numeri, funzioni e contesto DIVERSI. Devono sembrare usciti dallo stesso esame, senza esserne la copia.
            - Gli esercizi "theoretical" nascono invece dai materiali di teoria.
            - Se non ci sono temi d'esame tra i materiali, non generare esercizi "practical".

            Ricorda le regole di formattazione: le funzioni, le espressioni e i risultati con esponenti o frazioni vanno in LaTeX tra $$ su riga propria, sia nella traccia sia nei passi sia nella risposta.

            Ogni esercizio ha una soluzione guidata in 3-5 passi concreti e una risposta finale; "topic" è l'argomento in 2-4 parole; "source" è il titolo del materiale a cui ti sei ispirato e "quote" il passaggio originale (servono solo alla tracciabilità, NON vanno citati nella traccia).
            Indica "origin": "invented" se hai scritto tu la traccia ispirandoti ai materiali (è il caso normale), "fromMaterials" solo se la traccia è già presente come tale nei materiali e l'hai riportata.
            Includi "checkExpression" SOLO quando la risposta è un valore matematico verificabile in modo indipendente: mettici l'espressione da calcolare in sintassi Wolfram Alpha, il cui risultato deve coincidere con "answer". Omettilo per gli esercizi discorsivi.
            IMPORTANTE su checkExpression: dev'essere una FORMULA o una grandezza, non la descrizione di un compito. Wolfram accetta "integrate x^2 from 0 to 1", "eigenvalues {{2,1},{1,2}}", "roots of s^2+3s+2", "10*2000/(1000+2000)", "bode plot 1/(s+1)"; RIFIUTA fraseggi come "step response 1/(s^2+2s+1)", "voltage divider 10V 1kohm 2kohm", "beam deflection cantilever", "is G(s) stable". Se il calcolo è ingegneristico, scrivilo come espressione numerica esplicita con i valori già sostituiti.
            Schema: {"exercises":[{"category":"theoretical|practical","difficulty":"base|medio|avanzato","topic":"...","prompt":"...","steps":["...","..."],"answer":"...","source":"...","quote":"...","checkExpression":"...","origin":"invented|fromMaterials"}]}
            """
        case .reviewPoints:
            return common + """
            Compito: estrai i 5-10 concetti chiave dai materiali di teoria. Per ognuno: l'enunciato del concetto (statement), una domanda di autoverifica (question) e la risposta corretta basata sui materiali (answer).
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
            var category: String?
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

            enum CodingKeys: String, CodingKey {
                case category, difficulty, topic, prompt, answer, source, quote, checkExpression, origin
                case stepList = "steps"
            }
        }
        var exerciseItems: [Failable<Item>]
        var exercises: [Item] { exerciseItems.compactMap(\.value) }
        enum CodingKeys: String, CodingKey { case exerciseItems = "exercises" }
    }

    private struct AIReviewPointsDTO: Decodable, ArrayWrapped {
        static let arrayKey = "points"
        struct Point: Decodable { var statement: String; var question: String; var answer: String; var quote: String?; var source: String? }
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
            // Il caso di gran lunga più frequente: risposta interrotta
            // prima della fine, e nemmeno un elemento completo da salvare.
            return "La risposta del modello si è interrotta prima della fine. Riprova, oppure chiedi meno contenuti per volta."
        @unknown default:
            return "Il modello ha restituito un JSON non conforme."
        }
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
