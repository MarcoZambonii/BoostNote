import SwiftUI
import UIKit

// Correzione di una formula già posata sul foglio.
//
// Una formula composta è un'immagine, quindi di per sé non sarebbe più
// toccabile: quello che la rende modificabile è il LaTeX conservato in
// `sourceText`. Qui si corregge il sorgente, si vede subito l'anteprima
// composta, e alla conferma l'immagine sul foglio viene rifatta.
struct FormulaEditSheet: View {
    @Bindable var media: NoteMedia
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var latex: String
    @State private var isRendering = false
    @State private var errorMessage: String?

    init(media: NoteMedia, onSaved: @escaping () -> Void) {
        self.media = media
        self.onSaved = onSaved
        _latex = State(initialValue: media.sourceText ?? "")
    }

    private var canSave: Bool {
        !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRendering
    }

    var body: some View {
        BoostSheet(
            title: "Modifica formula",
            mode: .commit(verb: "Salva", enabled: canSave),
            onDismiss: { dismiss() },
            onConfirm: { Task { await save() } }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpace.s4) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CODICE LATEX")
                            .font(DesignFont.micro)
                            .foregroundStyle(DesignColor.textTertiary)
                        TextField("Formula", text: $latex, axis: .vertical)
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

                    VStack(alignment: .leading, spacing: 4) {
                        Text("ANTEPRIMA")
                            .font(DesignFont.micro)
                            .foregroundStyle(DesignColor.textTertiary)
                        // Si aggiorna mentre si scrive: l'errore di sintassi
                        // si vede subito, non dopo aver confermato.
                        RichTextBlock(text: latex, mathOnly: true)
                            .padding(.vertical, DesignSpace.s2)
                            .frame(maxWidth: .infinity)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: DesignRadius.md))
                            .overlay(RoundedRectangle(cornerRadius: DesignRadius.md).stroke(DesignColor.borderDefault))
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(DesignFont.label)
                            .foregroundStyle(DesignColor.danger)
                    }

                    if isRendering {
                        HStack(spacing: DesignSpace.s2) {
                            ProgressView().controlSize(.small)
                            Text("Compongo la formula…")
                                .font(DesignFont.caption)
                                .foregroundStyle(DesignColor.textTertiary)
                        }
                    }

                    BoostButton("Copia il codice LaTeX", icon: "doc.on.doc", fullWidth: true) {
                        UIPasteboard.general.string = latex
                    }
                }
                .padding(DesignSpace.s5)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isRendering = true
        errorMessage = nil
        defer { isRendering = false }

        guard let image = await LaTeXImageRenderer.image(for: trimmed),
              let data = image.pngData() else {
            errorMessage = "Non sono riuscito a comporre questa formula. Controlla il codice."
            return
        }
        media.data = data
        media.sourceText = trimmed
        // La formula ricomposta ha proporzioni diverse: la casella si
        // riadatta, altrimenti resterebbe schiacciata nella vecchia.
        media.width = Double(image.size.width)
        media.height = Double(image.size.height)
        onSaved()
        dismiss()
    }
}
