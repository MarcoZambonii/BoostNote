import SwiftUI

// Rinomina di nota e studio con la stessa testata commit di ogni altro
// foglio: l'alert resta riservato alle conferme distruttive (§5), un
// alert con dentro un TextField non è nella grammatica del sistema.
struct RenameSheet: View {
    let title: String
    let initialName: String
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        BoostSheet(
            title: title,
            mode: .commit(verb: "Salva", enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty),
            onDismiss: { dismiss() },
            onConfirm: {
                onSave(name.trimmingCharacters(in: .whitespaces))
                dismiss()
            }
        ) {
            VStack(alignment: .leading, spacing: DesignSpace.s2) {
                Text("NOME")
                    .font(DesignFont.micro)
                    .tracking(0.6)
                    .foregroundStyle(DesignColor.textTertiary)
                TextField("Nome", text: $name)
                    .textFieldStyle(.plain)
                    .font(DesignFont.body)
                    .padding(.horizontal, DesignSpace.s3)
                    .frame(height: DesignSize.control)
                    .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                    .focused($focused)
                    .submitLabel(.done)
                Spacer()
            }
            .padding(DesignSpace.s6)
        }
        .presentationDetents([.height(420)])
        .onAppear {
            name = initialName
            focused = true
        }
    }
}
