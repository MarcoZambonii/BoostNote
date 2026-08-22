import SwiftUI
import UIKit

struct MagicResult: Identifiable {
    let id = UUID()
    var action: MagicAction
    var recognizedText: String?
    // Da dove è passato il riconoscimento ("Gemini · cloud",
    // "Vision · locale"...): l'utente deve sapere se l'immagine è
    // rimasta sul dispositivo o è andata a un modello remoto.
    var recognizedVia: String?
    var resultText: String?
    var resultImageURLs: [URL] = []
    var graphExpression: String?
    var errorMessage: String?
    var captureRect: CGRect
}

struct MagicResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    var result: MagicResult
    var onInsert: (_ toPanel: Bool) -> Void
    // Testo riconosciuto corretto a mano → riesegue l'azione su quello.
    var onRetry: (_ editedText: String) -> Void
    @State private var editedText: String
    @State private var didCopy = false

    init(result: MagicResult, onInsert: @escaping (_ toPanel: Bool) -> Void, onRetry: @escaping (_ editedText: String) -> Void) {
        self.result = result
        self.onInsert = onInsert
        self.onRetry = onRetry
        _editedText = State(initialValue: result.recognizedText ?? "")
    }

    var body: some View {
        BoostSheet(
            title: "Penna magica",
            mode: .read,
            onDismiss: { dismiss() }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpace.s4) {
                    Label(result.action.label, systemImage: result.action.systemImage)
                        .font(DesignFont.cardTitle)
                        .foregroundStyle(result.action.color)

                    if result.recognizedText != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Text("RICONOSCIUTO")
                                    .font(DesignFont.micro)
                                    .foregroundStyle(DesignColor.textTertiary)
                                if let via = result.recognizedVia {
                                    Text("· \(via)")
                                        .font(DesignFont.caption)
                                        .foregroundStyle(DesignColor.textTertiary)
                                }
                            }
                            // Modificabile: se il riconoscimento ha
                            // sbagliato qualcosa, si corregge qui e si
                            // riesegue, senza dover riscrivere sul foglio.
                            TextField("Testo riconosciuto", text: $editedText, axis: .vertical)
                                .font(DesignFont.mono)
                                .foregroundStyle(DesignColor.textPrimary)
                                .textFieldStyle(.plain)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        .padding(DesignSpace.s3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md))
                        .overlay(RoundedRectangle(cornerRadius: DesignRadius.md).stroke(DesignColor.borderSubtle))

                        if editedText.trimmingCharacters(in: .whitespacesAndNewlines) != (result.recognizedText ?? ""),
                           !editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            BoostButton("Riesegui col testo corretto", icon: "arrow.clockwise", fullWidth: true) {
                                onRetry(editedText.trimmingCharacters(in: .whitespacesAndNewlines))
                                dismiss()
                            }
                        }
                    }

                    if let errorMessage = result.errorMessage {
                        Text(errorMessage)
                            .font(DesignFont.body)
                            .foregroundStyle(DesignColor.danger)
                    }

                    if let graphExpression = result.graphExpression {
                        Canvas { context, size in
                            _ = MathGraphRenderer.draw(expressionText: graphExpression, in: context, size: size)
                        }
                        .frame(height: 200)
                        .background(Color.white)
                        .overlay(RoundedRectangle(cornerRadius: DesignRadius.md).stroke(DesignColor.borderDefault))
                        .clipShape(RoundedRectangle(cornerRadius: DesignRadius.md))
                    }

                    if let resultText = result.resultText {
                        if result.action == .latex {
                            // Il testo È una formula: si compone
                            // direttamente, senza passare dal Markdown.
                            RichTextBlock(text: resultText, mathOnly: true)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: DesignRadius.md))
                                .overlay(RoundedRectangle(cornerRadius: DesignRadius.md).stroke(DesignColor.borderDefault))
                        } else {
                            // Spiega/Wolfram: Markdown completo (titoli,
                            // elenchi, grassetti, codice) con le formule
                            // tra $…$ composte da KaTeX.
                            RichTextBlock(text: resultText)
                        }
                    }

                    // Pod puramente visivi di Wolfram (diagramma di Bode,
                    // plot, circuiti...): non hanno un plaintext sensato,
                    // prima sparivano del tutto senza errore.
                    ForEach(result.resultImageURLs, id: \.self) { url in
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                            case .failure:
                                EmptyView()
                            default:
                                BoostState(kind: .loading, title: "Scarico il grafico…")
                                    .frame(height: 80)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: DesignRadius.md))
                        .overlay(RoundedRectangle(cornerRadius: DesignRadius.md).stroke(DesignColor.borderDefault))
                    }

                    if result.errorMessage == nil {
                        VStack(spacing: DesignSpace.s2) {
                            // "Disegna" apre direttamente il pannello
                            // Grafici precompilato; le altre azioni
                            // inseriscono il risultato come testo, con
                            // Wolfram che in più può aprirsi nel pannello
                            // (re-interrogabile). I widget sul foglio non
                            // esistono più.
                            if result.action == .draw {
                                BoostButton("Apri nel pannello Grafici", icon: "sidebar.right", tone: .primary, fullWidth: true) {
                                    onInsert(true)
                                    dismiss()
                                }
                            } else {
                                BoostButton(insertLabel, icon: "plus", tone: .primary, fullWidth: true) {
                                    onInsert(false)
                                    dismiss()
                                }

                                // Il foglio riceve la formula composta:
                                // chi vuole il sorgente (per Overleaf, per
                                // un'altra app) se lo porta via da qui.
                                if result.action == .latex, let resultText = result.resultText {
                                    BoostButton(didCopy ? "Codice LaTeX copiato" : "Copia il codice LaTeX",
                                                icon: didCopy ? "checkmark.circle.fill" : "doc.on.doc",
                                                fullWidth: true) {
                                        UIPasteboard.general.string = resultText
                                        withAnimation { didCopy = true }
                                    }
                                }

                                if result.action == .wolfram {
                                    BoostButton("Apri nel pannello", icon: "sidebar.right", fullWidth: true) {
                                        onInsert(true)
                                        dismiss()
                                    }
                                }
                            }
                        }
                        .padding(.top, DesignSpace.s2)
                    }
                }
                .padding(DesignSpace.s5)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var insertLabel: String {
        switch result.action {
        case .wolfram: "Inserisci come testo"
        case .latex: "Inserisci la formula composta"
        default: "Inserisci nella nota"
        }
    }
}
