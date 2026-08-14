import Foundation
import SwiftData

// Prepara i materiali di uno studio prima della generazione: scarica i
// file WeBeep, conserva i PDF scelti a mano ed estrae il testo da tutto
// (note scritte a mano incluse). Gira una volta sola alla creazione — il
// testo estratto resta su StudyMaterial, così l'OCR non si ripete a ogni
// rigenerazione.
@MainActor
enum StudyMaterialPreparation {

    // Avanzamento mostrato durante la creazione: l'estrazione da una
    // dispensa scansionata può richiedere parecchi secondi e l'utente
    // deve capire che sta succedendo qualcosa.
    struct Progress {
        var current: Int
        var total: Int
        var title: String
    }

    // Crea i StudyMaterial dello studio a partire dalle scelte fatte nel
    // flusso di creazione, con i dati già in pancia dove servono.
    static func prepare(
        sources: [StudySourceMaterial],
        pdfPayloads: [UUID: Data],
        for study: Study,
        in context: ModelContext,
        onProgress: @escaping (Progress) -> Void
    ) async {
        let token = WebeepService.savedToken

        for (index, source) in sources.enumerated() {
            onProgress(Progress(current: index + 1, total: sources.count, title: source.title))

            let material = StudyMaterial(
                title: source.title,
                subtitle: source.subtitle,
                kind: source.kind,
                isExamPaper: source.isExamPaper,
                noteID: source.noteID,
                study: study
            )
            context.insert(material)

            switch source.kind {
            case .note:
                guard let noteID = source.noteID else {
                    material.extractionError = "Nota non trovata."
                    continue
                }
                let descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID })
                guard let note = try? context.fetch(descriptor).first else {
                    material.extractionError = "La nota non esiste più."
                    continue
                }
                let text = await StudyMaterialExtractor.extractText(from: note)
                material.extractedText = text
                if text.isEmpty {
                    material.extractionError = "Nessun testo riconosciuto in questa nota."
                }

            case .file:
                guard let data = pdfPayloads[source.id] else {
                    material.extractionError = "File non disponibile."
                    continue
                }
                material.pdfData = data
                if let text = await StudyMaterialExtractor.extractText(fromPDF: data) {
                    material.extractedText = text
                } else {
                    material.extractionError = "Nessun testo estraibile da questo PDF."
                }

            case .webeep:
                // Il file WeBeep viene scaricato ora, non alla selezione:
                // così si evita di scaricare roba che l'utente poi toglie
                // dall'elenco prima di generare.
                guard let token else {
                    material.extractionError = "WeBeep non è collegato: riaccedi e ricrea lo studio."
                    continue
                }
                guard let file = source.webeepFile else {
                    material.extractionError = "Riferimento al file WeBeep mancante."
                    continue
                }
                do {
                    let data = try await WebeepService.downloadFile(file, token: token)
                    if isPDF(source.title, data: data) {
                        material.pdfData = data
                        if let text = await StudyMaterialExtractor.extractText(fromPDF: data) {
                            material.extractedText = text
                        } else {
                            material.extractionError = "Nessun testo estraibile da questo PDF."
                        }
                    } else {
                        material.extractionError = "Formato non supportato per l'estrazione (per ora solo PDF)."
                    }
                } catch {
                    material.extractionError = (error as? WebeepDownloadError)?.message ?? error.localizedDescription
                }
            }
        }
    }

    private static func isPDF(_ filename: String, data: Data) -> Bool {
        if filename.lowercased().hasSuffix(".pdf") { return true }
        // Firma "%PDF" in testa al file: più affidabile dell'estensione.
        return data.prefix(4).elementsEqual([0x25, 0x50, 0x44, 0x46])
    }
}
