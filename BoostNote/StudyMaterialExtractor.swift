import Foundation
import PDFKit
import PencilKit
import UIKit
import Vision

// Estrazione del testo dai materiali di uno studio.
//
// Tutto avviene ON-DEVICE e gratis (PDFKit + Vision): è la parte che
// prepara il contesto per la generazione, e farla passare da un modello a
// pagamento significherebbe pagare due volte lo stesso testo. Vale sia
// per le note (caselle di testo + scrittura a mano + PDF incorporati) sia
// per i PDF caricati o presi da WeBeep.
enum StudyMaterialExtractor {

    // Soglia sotto la quale una pagina PDF si considera "senza livello di
    // testo" (scansione o slide esportate come immagini) e si passa
    // all'OCR: alcuni PDF restituiscono due o tre caratteri spuri invece
    // di una stringa vuota.
    private static let minimumMeaningfulCharacters = 24

    // MARK: - Note

    // Il testo di una nota, da tutte le sue fonti. L'ordine segue quello
    // della pagina, così il contesto resta leggibile per il modello.
    // `onPage` avvisa a ogni pagina COMPLETATA (fatte, totale) — e il
    // totale conta tutte le pagine con del contenuto, non solo quelle
    // con scrittura a mano sopra: un PDF Notability da 167 pagine
    // importato come pagine della nota mostrava "pagina 2 di 5" mentre
    // il lavoro vero, le 167 pagine incorporate, correva invisibile.
    static func extractText(from note: Note, onPage: ((Int, Int) -> Void)? = nil) async -> String {
        var parts: [String] = []

        // 1. Caselle di testo (già digitali, nessun riconoscimento).
        let typed = note.textBoxes.map(\.text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !typed.isEmpty {
            parts.append(typed.joined(separator: "\n"))
        }

        // 2+3. Pagine: scrittura a mano e/o pagina PDF incorporata.
        // Prima si FOTOGRAFANO i dati (i @Model non si toccano dai task
        // paralleli), poi si lavora 4 pagine alla volta: su una lezione
        // Notability da 167 pagine la differenza è tra ~10 minuti in
        // fila indiana e una frazione. L'ordine si ricompone alla fine.
        struct PageWork {
            let order: Int
            let drawing: Data?
            let pdf: Data?
        }
        let snapshots: [(Data?, Data?)]
        if note.isWhiteboard || note.pages.isEmpty {
            // Lavagna, o note create prima del modello a pagine (il
            // disegno sta ancora nel campo legacy).
            snapshots = [(note.drawingData, nil)]
        } else {
            snapshots = note.sortedPages.map { ($0.drawingData, $0.pdfPageData) }
        }
        let work = snapshots.enumerated()
            .filter { $0.element.0 != nil || $0.element.1 != nil }
            .map { PageWork(order: $0.offset, drawing: $0.element.0, pdf: $0.element.1) }

        if !work.isEmpty {
            let pageTexts = await withTaskGroup(of: (Int, String?).self) { group -> [Int: String] in
                var results: [Int: String] = [:]
                var next = 0
                var completed = 0
                let maxConcurrent = 4

                func addTask(_ job: PageWork) {
                    group.addTask {
                        var chunk: [String] = []
                        if let handwriting = await recognizeHandwriting(in: job.drawing) {
                            chunk.append(handwriting)
                        }
                        if let pdf = job.pdf, let text = await extractText(fromPDF: pdf) {
                            chunk.append(text)
                        }
                        return (job.order, chunk.isEmpty ? nil : chunk.joined(separator: "\n\n"))
                    }
                }

                while next < work.count && next < maxConcurrent {
                    addTask(work[next]); next += 1
                }
                while let (order, text) = await group.next() {
                    completed += 1
                    onPage?(completed, work.count)
                    if let text { results[order] = text }
                    if next < work.count { addTask(work[next]); next += 1 }
                }
                return results
            }
            for job in work {
                if let text = pageTexts[job.order] { parts.append(text) }
            }
        }

        // 4. Media appoggiati sul foglio: PDF e immagini con del testo.
        for media in note.media {
            switch media.kind {
            case .pdf:
                if let text = await extractText(fromPDF: media.data) { parts.append(text) }
            // Anche le formule composte sono immagini, ma di tipografia
            // pulita: Vision le legge molto meglio della scrittura a mano.
            case .image, .formula:
                if let image = UIImage(data: media.data), let text = await recognizeText(in: image) {
                    parts.append(text)
                }
            }
        }

        return parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Prompt di trascrizione fedele per il modello vision. Regole nate
    // dai limiti misurati di Vision OCR: la matematica scritta a mano è
    // il punto dove "xdx" al posto di un integrale definito rovina tutto
    // il materiale a valle.
    private static let handwritingPrompt = """
    Trascrivi fedelmente tutto ciò che è scritto a mano in questa pagina di appunti universitari.
    - Mantieni la struttura: una riga di appunti per riga di testo, gli elenchi come elenchi.
    - Ogni formula o espressione matematica va scritta in LaTeX: in linea tra $ … $ se sta dentro una frase, su riga propria tra $$ … $$ se è centrata o autonoma.
    - Non aggiungere spiegazioni, commenti, titoli o intestazioni tue: SOLO la trascrizione.
    - Se una parola è illeggibile scrivi [?] al suo posto, senza tirare a indovinare.
    - Se la pagina non contiene testo (solo disegni o schizzi), rispondi con una stringa vuota.
    """

    // La scrittura a mano è l'unico posto dove Vision OCR fallisce
    // davvero (un integrale definito letto come "xdx"): se un provider
    // che legge immagini è configurato, la pagina passa dal modello —
    // catena di lettura, tier Lite, una chiamata per pagina. Vision resta
    // il fallback per ogni fallimento (niente chiave, niente rete, quota
    // finita): l'estrazione non deve mai bloccarsi, al massimo peggiora.
    private static func transcribeWithModel(_ image: UIImage) async -> String? {
        guard AIService.selectedProvider != .appleLocal, AIService.isConfigured else { return nil }
        guard case .success(let text) = await AIService.generate(prompt: handwritingPrompt, image: image, waitsForRateLimit: true, imageMaxDimension: 2048) else {
            return nil
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    // Non-private: sono i primitivi per pagina su cui poggia anche la
    // coda di ingestione del vault (VaultIngestionService).
    static func recognizeHandwriting(in data: Data?) async -> String? {
        guard let data, let drawing = try? PKDrawing(data: data) else { return nil }
        let bounds = drawing.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        // `PKDrawing.image(from:scale:)` produce un'immagine con SFONDO
        // TRASPARENTE, e su quella Vision non riconosce assolutamente
        // nulla (provato: zero blocchi di testo su una pagina piena di
        // scrittura; con lo stesso disegno su fondo bianco il testo esce).
        // Va quindi composta sul bianco come sul foglio vero.
        //
        // Scala fino a 4x invece di 2x: sempre nel test, la stessa
        // espressione passava da "7+5" a "7+15" — sulla scrittura a mano
        // la risoluzione conta più di quanto sembri. Il tetto sul lato
        // massimo evita immagini enormi su una lavagna molto popolata.
        let longestSide = max(bounds.width, bounds.height)
        let scale = max(1.0, min(4.0, 6000 / longestSide))
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let ink = drawing.image(from: bounds, scale: scale)

        let renderer = UIGraphicsImageRenderer(size: size)
        let composed = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ink.draw(in: CGRect(origin: .zero, size: size))
        }
        // Prima il modello vision (legge la matematica), poi Vision OCR
        // come rete di sicurezza.
        if let transcribed = await transcribeWithModel(composed) {
            return transcribed
        }
        return await recognizeText(in: composed)
    }

    // MARK: - PDF

    // Testo di un PDF: prima il livello di testo vero (istantaneo e
    // fedele), poi OCR pagina per pagina solo dove manca — così un PDF
    // digitale non paga il costo dell'OCR, e uno scansionato funziona
    // comunque.
    static func extractText(fromPDF data: Data) async -> String? {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }

        // Prima passata: il livello di testo vero, che è istantaneo.
        // Si annota quali pagine ne sono prive e vanno passate all'OCR.
        var parts = [String](repeating: "", count: document.pageCount)
        var needsOCR: [Int] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let embedded = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if embedded.count >= minimumMeaningfulCharacters {
                parts[index] = embedded
            } else {
                parts[index] = embedded
                needsOCR.append(index)
            }
        }

        // Seconda passata: OCR delle sole pagine senza testo, IN
        // PARALLELO. Era il vero collo di bottiglia — su una dispensa
        // scansionata di 40 pagine, una alla volta significa minuti di
        // attesa mentre i core restano fermi. Concorrenza limitata a 4:
        // ogni pagina viene renderizzata a 2x, e senza tetto la memoria
        // esplode su documenti lunghi.
        if !needsOCR.isEmpty {
            let recognized = await withTaskGroup(of: (Int, String?).self) { group -> [Int: String] in
                var results: [Int: String] = [:]
                var next = 0
                let maxConcurrent = 4

                func addTask(_ index: Int) {
                    group.addTask {
                        guard let page = document.page(at: index),
                              let image = render(page: page) else { return (index, nil) }
                        return (index, await recognizePDFPage(in: image))
                    }
                }

                while next < needsOCR.count && next < maxConcurrent {
                    addTask(needsOCR[next]); next += 1
                }
                while let (index, text) = await group.next() {
                    if let text { results[index] = text }
                    if next < needsOCR.count {
                        addTask(needsOCR[next]); next += 1
                    }
                }
                return results
            }
            for (index, text) in recognized where !text.isEmpty {
                parts[index] = text
            }
        }

        let joined = parts.filter { !$0.isEmpty }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    // Una pagina PDF senza livello di testo può essere due cose molto
    // diverse: una scansione a stampa (Vision la legge bene, gratis) o
    // una pagina scritta a mano esportata da un'altra app — Notability,
    // GoodNotes — dove Vision produce spazzatura. A decidere è la
    // CONFIDENZA di Vision stessa: alta sulla tipografia, bassa sul
    // corsivo. Così una dispensa scansionata da 100 pagine resta gratis,
    // e una lezione manoscritta esportata in PDF passa dal modello come
    // le note scritte a mano nell'app.
    static func recognizePDFPage(in image: UIImage) async -> String? {
        let vision = await recognizeTextWithConfidence(in: image)
        if let vision, vision.confidence >= 0.6, vision.text.count >= minimumMeaningfulCharacters {
            return vision.text
        }
        if let transcribed = await transcribeWithModel(image) {
            return transcribed
        }
        // Il modello non c'era o ha fallito: meglio il testo incerto di
        // Vision che una pagina vuota.
        return vision?.text
    }

    static func render(page: PDFPage) -> UIImage? {
        let pageRect = page.bounds(for: .mediaBox)
        guard pageRect.width > 1, pageRect.height > 1 else { return nil }
        // 2x per dare a Vision abbastanza risoluzione sul corpo del testo,
        // con un tetto per non far esplodere la memoria su pagine A0.
        let scale = min(2.0, 3000 / max(pageRect.width, pageRect.height))
        let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
    }

    // MARK: - OCR

    // Come recognizeText, ma riporta anche quanto Vision si fida di ciò
    // che ha letto: media delle confidenze per riga, pesata sulla
    // lunghezza (una riga lunga letta male pesa più di una sigla letta
    // bene). Vision dà valori grossolani (~0.3 corsivo incerto, ~0.5
    // dubbio, ~1.0 stampa pulita): la soglia 0.6 usata sopra separa
    // stampa da manoscritto senza tarature fini.
    static func recognizeTextWithConfidence(in image: UIImage) async -> (text: String, confidence: Double)? {
        guard let cgImage = image.cgImage else { return nil }
        return await withCheckedContinuation { continuation in
            // OneShotContinuation: se `perform` lancia senza aver chiamato
            // il completion, la continuation va comunque ripresa — vedi il
            // commento in MagicPenService.
            let resume = OneShotContinuation(continuation)
            let request = VNRecognizeTextRequest { request, _ in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    resume.resume(nil)
                    return
                }
                var lines: [String] = []
                var weightedConfidence = 0.0
                var totalWeight = 0.0
                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    lines.append(candidate.string)
                    let weight = Double(candidate.string.count)
                    weightedConfidence += Double(candidate.confidence) * weight
                    totalWeight += weight
                }
                let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, totalWeight > 0 else {
                    resume.resume(nil)
                    return
                }
                resume.resume((text, weightedConfidence / totalWeight))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["it-IT", "en-US"]
            request.automaticallyDetectsLanguage = true

            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    resume.resume(nil)
                }
            }
        }
    }

    // A differenza di MagicPenService.recognizeText (pensato per una
    // singola espressione cerchiata), qui si conserva l'andata a capo: su
    // una pagina intera la struttura in righe aiuta il modello a capire
    // titoli, elenchi e formule separate.
    static func recognizeText(in image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        return await withCheckedContinuation { continuation in
            let resume = OneShotContinuation(continuation)
            let request = VNRecognizeTextRequest { request, _ in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    resume.resume(nil)
                    return
                }
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                resume.resume(text.isEmpty ? nil : text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["it-IT", "en-US"]
            request.automaticallyDetectsLanguage = true

            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    resume.resume(nil)
                }
            }
        }
    }
}
