import SwiftUI

struct MagicResult: Identifiable {
    let id = UUID()
    var action: MagicAction
    var recognizedText: String?
    var resultText: String?
    var graphExpression: String?
    var errorMessage: String?
    var captureRect: CGRect
}

struct MagicResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    var result: MagicResult
    var onInsert: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpace.s4) {
                    Label(result.action.label, systemImage: result.action.systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(result.action.color)

                    if let recognizedText = result.recognizedText {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("RICONOSCIUTO")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DesignColor.textTertiary)
                            Text(recognizedText)
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundStyle(DesignColor.textPrimary)
                        }
                        .padding(DesignSpace.s3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md))
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
                        Text(resultText)
                            .font(.system(size: 14))
                            .foregroundStyle(DesignColor.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if result.errorMessage == nil {
                        Button {
                            onInsert()
                            dismiss()
                        } label: {
                            Label("Inserisci nella nota", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(result.action.color)
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
}
