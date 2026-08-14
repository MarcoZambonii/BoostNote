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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpace.s5) {
                    VStack(alignment: .leading, spacing: DesignSpace.s2) {
                        Text("ESERCIZIO SEGNALATO")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(DesignColor.textTertiary)
                        Text(exercisePrompt)
                            .font(.system(size: 13))
                            .foregroundStyle(DesignColor.textSecondary)
                            .lineLimit(4)
                            .padding(DesignSpace.s3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: DesignSpace.s2) {
                        Text("COSA NON VA?")
                            .font(.system(size: 11, weight: .semibold))
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
                                        .font(.system(size: 14))
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
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(DesignColor.textTertiary)
                        TextField("Es. il segno del secondo passaggio è invertito", text: $details, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .lineLimit(3...6)
                            .padding(DesignSpace.s3)
                            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                        Text("Più sei preciso, più è probabile che l'esercizio rigenerato non ripeta l'errore.")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignColor.textTertiary)
                    }

                    VStack(spacing: DesignSpace.s3) {
                        Button {
                            onRegenerate(feedback)
                            dismiss()
                        } label: {
                            HStack(spacing: DesignSpace.s2) {
                                Image(systemName: "arrow.clockwise")
                                Text("Rigenera con questa correzione")
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DesignColor.textOnBrand)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DesignSpace.s3)
                            .background(
                                feedback.isEmpty ? DesignColor.gray300 : DesignColor.brandPrimary,
                                in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(feedback.isEmpty)

                        Button {
                            onReportOnly(feedback)
                            dismiss()
                        } label: {
                            Text("Segnala e basta")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(DesignColor.textSecondary)
                        }
                        .buttonStyle(.plain)

                        Text("Rigenerare usa una chiamata al modello e sostituisce solo questo esercizio: gli altri restano com'erano.")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignColor.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(DesignSpace.s5)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(DesignColor.surfacePage)
            .navigationTitle("Segnala errore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}
