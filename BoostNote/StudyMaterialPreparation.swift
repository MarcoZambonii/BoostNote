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
        // Dettaglio dentro il materiale corrente ("pagina 3 di 12"):
        // con il modello vision ogni pagina scritta a mano costa qualche
        // secondo, e senza questo la barra sembra ferma.
        var detail: String?
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

        // Le sorgenti dal Vault si risincronizzano PRIMA (decisione
        // "al momento dell'uso"): una passata di hash per cartella, e si
        // rileggono solo le pagine cambiate delle note vive. Su un Vault
        // fresco non parte nessuna chiamata.
        let vaultIDs = sources.compactMap(\.vaultDocumentID)
        if !vaultIDs.isEmpty {
            onProgress(Progress(current: 1, total: sources.count, title: "Aggiorno il Vault"))
            let descriptor = FetchDescriptor<VaultDocument>()
            let documents = ((try? context.fetch(descriptor)) ?? []).filter { vaultIDs.contains($0.id) }
            var refreshed: Set<UUID> = []
            for document in documents {
                guard let folder = document.folder, !refreshed.contains(folder.id) else { continue }
                refreshed.insert(folder.id)
                await VaultIngestionService.ensureFresh(for: folder, in: context)
            }
        }

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
            case .vault:
                // Il guadagno del Vault: il testo c'è già, qui si copia
                // e basta — zero OCR, zero chiamate.
                guard let documentID = source.vaultDocumentID else {
                    material.extractionError = "Riferimento al Vault mancante."
                    continue
                }
                let descriptor = FetchDescriptor<VaultDocument>(predicate: #Predicate { $0.id == documentID })
                guard let document = try? context.fetch(descriptor).first else {
                    material.extractionError = "Il documento non è più nel Vault."
                    continue
                }
                material.pdfData = document.pdfData
                let text = document.fullText
                material.extractedText = text
                if text.isEmpty {
                    material.extractionError = document.pendingCount > 0
                        ? "Il Vault non ha ancora letto questo documento: apri il Vault e attendi la lettura."
                        : "Nessun testo in questo documento del Vault."
                } else if document.pendingCount > 0 {
                    // Informativo, non bloccante: si genera con quello
                    // che c'è, dicendo quanto manca.
                    material.extractionError = "Vault letto in parte: \(document.readCount) di \(document.pages.count) pagine."
                }

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
                let sourceCount = sources.count
                let sourceTitle = source.title
                let text = await StudyMaterialExtractor.extractText(from: note) { page, totalPages in
                    // Il callback arriva dal pool dell'estrattore, non dal
                    // MainActor: lo stato della UI si tocca solo di là.
                    Task { @MainActor in
                        onProgress(Progress(
                            current: index + 1, total: sourceCount, title: sourceTitle,
                            detail: totalPages > 1 ? "pagina \(page) di \(totalPages)" : nil
                        ))
                    }
                }
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
