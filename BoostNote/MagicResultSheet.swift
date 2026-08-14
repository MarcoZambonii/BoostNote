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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpace.s4) {
                    Label(result.action.label, systemImage: result.action.systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(result.action.color)

                    if result.recognizedText != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Text("RICONOSCIUTO")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(DesignColor.textTertiary)
                                if let via = result.recognizedVia {
                                    Text("· \(via)")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(DesignColor.textTertiary)
                                }
                            }
                            // Modificabile: se il riconoscimento ha
                            // sbagliato qualcosa, si corregge qui e si
                            // riesegue, senza dover riscrivere sul foglio.
                            TextField("Testo riconosciuto", text: $editedText, axis: .vertical)
                                .font(.system(size: 14, design: .monospaced))
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
                            Button {
                                onRetry(editedText.trimmingCharacters(in: .whitespacesAndNewlines))
                                dismiss()
                            } label: {
                                Label("Riesegui col testo corretto", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(result.action.color)
                        }
                    }

                    if let errorMessage = result.errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 14))
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
                                ProgressView().frame(height: 80)
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
                                Button {
                                    onInsert(true)
                                    dismiss()
                                } label: {
                                    Label("Apri nel pannello Grafici", systemImage: "sidebar.right")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(result.action.color)
                            } else {
                                Button {
                                    onInsert(false)
                                    dismiss()
                                } label: {
                                    Label(insertLabel, systemImage: "plus.circle.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(result.action.color)

                                // Il foglio riceve la formula composta:
                                // chi vuole il sorgente (per Overleaf, per
                                // un'altra app) se lo porta via da qui.
                                if result.action == .latex, let resultText = result.resultText {
                                    Button {
                                        UIPasteboard.general.string = resultText
                                        withAnimation { didCopy = true }
                                    } label: {
                                        Label(
                                            didCopy ? "Codice LaTeX copiato" : "Copia il codice LaTeX",
                                            systemImage: didCopy ? "checkmark" : "doc.on.doc"
                                        )
                                        .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(result.action.color)
                                }

                                if result.action == .wolfram {
                                    Button {
                                        onInsert(true)
                                        dismiss()
                                    } label: {
                                        Label("Apri nel pannello", systemImage: "sidebar.right")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(result.action.color)
                                }
                            }
                        }
                        .padding(.top, DesignSpace.s2)
                    }
                }
                .padding(DesignSpace.s5)
            }
            .navigationTitle("Penna magica")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
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
