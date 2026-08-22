import SwiftUI

// "Segnala errore" su un esercizio: chiede COSA non va e usa la risposta
// per rigenerare quell'esercizio soltanto.
//
// Perché non rigenerare il modulo intero: costerebbe una chiamata in più
// e soprattutto butterebbe via gli altri esercizi, che magari erano
// buoni. E perché chiedere il motivo invece di rigenerare al buio: senza
// sapere cosa non andava il modello rifarebbe lo stesso errore — il
// motivo entra nel prompt come vincolo esplicito.
struct ExerciseReportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let exercisePrompt: String
    var onReportOnly: (String) -> Void
    var onRegenerate: (String) -> Void

    @State private var selectedReason: String?
    @State private var details = ""

    // Motivi tarati su ciò che va storto davvero in un esercizio
    // generato, così il modello riceve un vincolo utile e non un generico
    // "è sbagliato".
    private static let reasons = [
        "La soluzione è sbagliata",
        "La traccia non è chiara o è incompleta",
        "Non c'entra con i miei materiali",
        "Difficoltà sbagliata",
        "I dati non sono coerenti"
    ]

    private var feedback: String {
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        return [selectedReason, trimmed.isEmpty ? nil : trimmed]
            .compactMap { $0 }
            .joined(separator: ". ")
    }

    var body: some View {
        BoostSheet(
            title: "Segnala errore",
            mode: .commit(verb: "Rigenera", enabled: !feedback.isEmpty),
            onDismiss: { dismiss() },
            onConfirm: {
                onRegenerate(feedback)
                dismiss()
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpace.s5) {
                    VStack(alignment: .leading, spacing: DesignSpace.s2) {
                        Text("ESERCIZIO SEGNALATO")
                            .font(DesignFont.micro)
                            .tracking(0.6)
                            .foregroundStyle(DesignColor.textTertiary)
                        Text(exercisePrompt)
                            .font(DesignFont.label)
                            .foregroundStyle(DesignColor.textSecondary)
                            .lineLimit(4)
                            .padding(DesignSpace.s3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: DesignSpace.s2) {
                        Text("COSA NON VA?")
                            .font(DesignFont.micro)
                            .tracking(0.6)
                            .foregroundStyle(DesignColor.textTertiary)
                        ForEach(Self.reasons, id: \.self) { reason in
                            Button {
                                selectedReason = (selectedReason == reason) ? nil : reason
                            } label: {
                                HStack(spacing: DesignSpace.s3) {
                                    Image(systemName: selectedReason == reason ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(selectedReason == reason ? DesignColor.brandPrimary : DesignColor.borderDefault)
                                    Text(reason)
                                        .font(DesignFont.body)
                                        .foregroundStyle(DesignColor.textPrimary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: DesignSpace.s2) {
                        Text("DETTAGLI (FACOLTATIVI)")
                            .font(DesignFont.micro)
                            .tracking(0.6)
                            .foregroundStyle(DesignColor.textTertiary)
                        TextField("Es. il segno del secondo passaggio è invertito", text: $details, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(DesignFont.body)
                            .lineLimit(3...6)
                            .padding(DesignSpace.s3)
                            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                        Text("Più sei preciso, più è probabile che l'esercizio rigenerato non ripeta l'errore.")
                            .font(DesignFont.caption)
                            .foregroundStyle(DesignColor.textTertiary)
                    }

                    VStack(spacing: DesignSpace.s3) {
                        BoostButton("Segnala e basta", tone: .ghost, fullWidth: true) {
                            onReportOnly(feedback)
                            dismiss()
                        }

                        Text("«Rigenera» usa una chiamata al modello e sostituisce solo questo esercizio: gli altri restano com'erano. «Segnala e basta» lo marca soltanto.")
                            .font(DesignFont.caption)
                            .foregroundStyle(DesignColor.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(DesignSpace.s5)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(DesignColor.surfacePage)
        }
        .presentationDetents([.large])
    }
}
