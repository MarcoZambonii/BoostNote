import SwiftUI

struct GraphingSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var expressionText = "x^2 - 9"

    private var isValid: Bool { (try? MathExpression(expressionText)) != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: DesignSpace.s4) {
                HStack {
                    Text("y =")
                        .foregroundStyle(DesignColor.textSecondary)
                    TextField("es. sin(x) * 2", text: $expressionText)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.plain)
                }
                .padding(DesignSpace.s3)
                .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                .padding(.horizontal)

                if !isValid {
                    Text("Espressione non valida")
                        .font(.caption)
                        .foregroundStyle(DesignColor.danger)
                }

                Canvas { context, size in
                    _ = MathGraphRenderer.draw(expressionText: expressionText, in: context, size: size)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DesignColor.surfacePage)
                .overlay(RoundedRectangle(cornerRadius: DesignRadius.md).stroke(DesignColor.borderDefault))
                .padding(.horizontal)
                .padding(.bottom)
            }
            .padding(.top)
            .navigationTitle("Grafici")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}
