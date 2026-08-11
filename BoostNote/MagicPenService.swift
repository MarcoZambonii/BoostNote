import UIKit
import Vision
import FoundationModels

// Riconoscimento del testo scritto a mano nell'area cerchiata (Vision,
// on-device), più le chiamate a Wolfram Alpha e Claude per le azioni
// della penna magica.
enum LocalModelUnavailableReason: Error {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case other

    init(_ reason: SystemLanguageModel.Availability.UnavailableReason) {
        switch reason {
        case .deviceNotEligible: self = .deviceNotEligible
        case .appleIntelligenceNotEnabled: self = .appleIntelligenceNotEnabled
        case .modelNotReady: self = .modelNotReady
        @unknown default: self = .other
        }
    }

    var message: String {
        switch self {
        case .deviceNotEligible:
            "Questo iPad non supporta il modello Apple locale (serve un chip M1 o più recente)."
        case .appleIntelligenceNotEnabled:
            "Attiva Apple Intelligence in Impostazioni → Apple Intelligence e Siri per usare la spiegazione locale."
        case .modelNotReady:
            "Il modello Apple si sta ancora scaricando/preparando. Riprova tra poco."
        case .other:
            "Il modello locale non è disponibile al momento."
        }
    }
}

enum MagicPenService {
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
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false

            DispatchQueue.global(qos: .userInitiated).async {
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
            }
        }
    }

    static func queryWolfram(text: String, appID: String) async -> String? {
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.wolframalpha.com/v2/query?input=\(encoded)&appid=\(appID)&format=plaintext&output=XML") else {
            return nil
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return WolframPodParser.parse(data)
    }

    // Spiegazione via modello Apple locale (Foundation Models, on-device,
    // gratis, richiede Apple Intelligence attiva e un iPad compatibile —
    // es. chip M1 o A17 Pro+). Se non disponibile, il chiamante può
    // ripiegare su queryClaude se l'utente ha configurato una chiave.
    static func explainLocally(text: String) async -> Result<String, LocalModelUnavailableReason> {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            return .failure(LocalModelUnavailableReason(reason))
        }

        let session = LanguageModelSession(model: model)
        let prompt = "Spiega in modo semplice, breve e passo passo questo appunto scritto a mano (il testo arriva da riconoscimento ottico e può contenere errori): \(text)"
        guard let response = try? await session.respond(to: prompt) else {
            return .failure(.other)
        }
        return .success(response.content)
    }

    static func queryClaude(text: String, apiKey: String) async -> String? {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let prompt = "Spiega in modo semplice, breve e passo passo questo appunto scritto a mano (il testo arriva da riconoscimento ottico e può contenere errori): \(text)"
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 400,
            "messages": [["role": "user", "content": prompt]]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData

        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else { return nil }
        return text
    }

    static func searchURL(for text: String) -> URL? {
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}

// Estrae i pod testuali dalla risposta XML di Wolfram Alpha (Full Results API).
private enum WolframPodParser {
    static func parse(_ data: Data) -> String? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.summary.isEmpty ? nil : delegate.summary
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var summary = ""
        private var currentElement = ""
        private var currentPodTitle = ""
        private var currentPlaintext = ""
        private var success = true

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            currentElement = elementName
            if elementName == "queryresult", attributeDict["success"] == "false" {
                success = false
            }
            if elementName == "pod" {
                currentPodTitle = attributeDict["title"] ?? ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if currentElement == "plaintext" {
                currentPlaintext += string
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "plaintext" {
                let trimmed = currentPlaintext.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if !summary.isEmpty { summary += "\n\n" }
                    summary += currentPodTitle.isEmpty ? trimmed : "\(currentPodTitle): \(trimmed)"
                }
                currentPlaintext = ""
            }
        }

        func parserDidEndDocument(_ parser: XMLParser) {
            if !success && summary.isEmpty {
                summary = "Wolfram Alpha non ha capito l'espressione. Prova a scrivere più chiaro."
            }
        }
    }
}
