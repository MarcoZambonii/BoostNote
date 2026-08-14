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
    static func extractText(from note: Note) async -> String {
        var parts: [String] = []

        // 1. Caselle di testo (già digitali, nessun riconoscimento).
        let typed = note.textBoxes.map(\.text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !typed.isEmpty {
            parts.append(typed.joined(separator: "\n"))
        }

        // 2. Scrittura a mano: la lavagna ha un unico disegno, le note
        // normali uno per pagina.
        if note.isWhiteboard {
            if let handwriting = await recognizeHandwriting(in: note.drawingData) {
                parts.append(handwriting)
            }
        } else {
            for page in note.sortedPages {
                if let handwriting = await recognizeHandwriting(in: page.drawingData) {
                    parts.append(handwriting)
                }
                // 3. Pagine che sono in realtà un PDF importato.
                if let pdfData = page.pdfPageData, let text = await extractText(fromPDF: pdfData) {
                    parts.append(text)
                }
            }
            // Note create prima del modello a pagine: il disegno sta ancora
            // nel campo legacy.
            if note.pages.isEmpty, let handwriting = await recognizeHandwriting(in: note.drawingData) {
                parts.append(handwriting)
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

    private static func recognizeHandwriting(in data: Data?) async -> String? {
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
                        return (index, await recognizeText(in: image))
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

    private static func render(page: PDFPage) -> UIImage? {
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

    // A differenza di MagicPenService.recognizeText (pensato per una
    // singola espressione cerchiata), qui si conserva l'andata a capo: su
    // una pagina intera la struttura in righe aiuta il modello a capire
    // titoli, elenchi e formule separate.
    static func recognizeText(in image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: nil)
                    return
                }
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["it-IT", "en-US"]
            request.automaticallyDetectsLanguage = true

            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
            }
        }
    }
}
