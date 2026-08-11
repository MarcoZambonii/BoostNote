import SwiftUI
import Combine

// Contenuto SwiftUI dei widget inseribili sul foglio (grafico, to-do,
// pomodoro, wolfram). Ogni widget legge/scrive il proprio stato in
// `NoteWidget.dataJSON` tramite decode/encode. Stile card bianca con
// titolo + "x", ricalcato dal design Figma.
struct NoteWidgetContentView: View {
    var widget: NoteWidget
    var onUpdate: () -> Void
    var onDelete: () -> Void

    var body: some View {
        Group {
            switch widget.kind {
            case .graph: GraphWidgetContentView(widget: widget, onUpdate: onUpdate, onDelete: onDelete)
            case .todo: TodoWidgetContentView(widget: widget, onUpdate: onUpdate, onDelete: onDelete)
            case .pomodoro: PomodoroWidgetContentView(onDelete: onDelete)
            case .wolfram: WolframWidgetContentView(onDelete: onDelete)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Guscio comune a tutti i widget: titolo a sinistra, "x" a destra, card
// bianca arrotondata con ombra morbida.
struct WidgetCard<Content: View>: View {
    var title: String
    var onDelete: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignColor.textPrimary)
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignColor.textTertiary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DesignSpace.s4)
            .padding(.top, DesignSpace.s4)
            .padding(.bottom, DesignSpace.s2)

            content()
                .padding(.horizontal, DesignSpace.s4)
                .padding(.bottom, DesignSpace.s4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignColor.surfacePage, in: RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous)
                .stroke(DesignColor.borderSubtle, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
    }
}

// MARK: - Grafico

struct GraphWidgetContentView: View {
    var widget: NoteWidget
    var onUpdate: () -> Void
    var onDelete: () -> Void

    @State private var expression = "x^2 - 9"

    var body: some View {
        WidgetCard(title: "Grafico", onDelete: onDelete) {
            VStack(spacing: DesignSpace.s2) {
                TextField("y =", text: $expression)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.sm))
                    .onChange(of: expression) { _, newValue in
                        var state = widget.decode(GraphWidgetState.self, default: GraphWidgetState())
                        state.expression = newValue
                        widget.encode(state)
                        onUpdate()
                    }

                // GeoGebra vero e interattivo: pinch-zoom, trascinamento,
                // traccia — non solo un disegno statico.
                GeoGebraGraphView(expression: expression)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: DesignRadius.sm))
            }
        }
        .onAppear {
            expression = widget.decode(GraphWidgetState.self, default: GraphWidgetState()).expression
        }
    }
}

// MARK: - To-Do

struct TodoWidgetContentView: View {
    var widget: NoteWidget
    var onUpdate: () -> Void
    var onDelete: () -> Void

    @State private var items: [ChecklistItem] = []
    @State private var newText = ""

    var body: some View {
        WidgetCard(title: "To-do", onDelete: onDelete) {
            VStack(alignment: .leading, spacing: DesignSpace.s3) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignSpace.s2) {
                        ForEach(items) { item in
                            Button { toggle(item) } label: {
                                HStack(spacing: 10) {
                                    checkbox(isDone: item.isDone)
                                    Text(item.text)
                                        .font(.system(size: 14))
                                        .strikethrough(item.isDone)
                                        .foregroundStyle(item.isDone ? DesignColor.textTertiary : DesignColor.textPrimary)
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack {
                    TextField("Aggiungi elemento", text: $newText)
                        .font(.system(size: 13))
                        .textFieldStyle(.plain)
                        .onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(DesignColor.brandPrimary)
                    }
                    .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(8)
                .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.sm))
            }
        }
        .onAppear {
            items = widget.decode(TodoWidgetState.self, default: TodoWidgetState()).items
        }
    }

    @ViewBuilder
    private func checkbox(isDone: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isDone ? DesignColor.brandPrimary : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isDone ? Color.clear : DesignColor.borderDefault, lineWidth: 1.5)
            )
            .overlay {
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 22, height: 22)
    }

    private func add() {
        let trimmed = newText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        items.append(ChecklistItem(text: trimmed))
        newText = ""
        save()
    }

    private func toggle(_ item: ChecklistItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isDone.toggle()
        save()
    }

    private func save() {
        widget.encode(TodoWidgetState(items: items))
        onUpdate()
    }
}

// MARK: - Pomodoro

struct PomodoroWidgetContentView: View {
    var onDelete: () -> Void

    @State private var totalSeconds = 25 * 60
    @State private var remainingSeconds = 25 * 60
    @State private var isRunning = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var timeLabel: String {
        String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    var body: some View {
        WidgetCard(title: "Pomodoro", onDelete: onDelete) {
            VStack(spacing: DesignSpace.s4) {
                Text(timeLabel)
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .foregroundStyle(DesignColor.brandPrimary)

                HStack(spacing: DesignSpace.s3) {
                    stepButton("minus") {
                        totalSeconds = max(60, totalSeconds - 5 * 60)
                        if !isRunning { remainingSeconds = totalSeconds }
                    }

                    Button(isRunning ? "Pausa" : "Avvia") {
                        isRunning.toggle()
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, DesignSpace.s5)
                    .padding(.vertical, DesignSpace.s2)
                    .background(DesignColor.brandPrimary, in: Capsule())
                    .buttonStyle(.plain)

                    stepButton("plus") {
                        totalSeconds += 5 * 60
                        if !isRunning { remainingSeconds = totalSeconds }
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            guard isRunning, remainingSeconds > 0 else { return }
            remainingSeconds -= 1
        }
    }

    @ViewBuilder
    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)
                .frame(width: 32, height: 32)
                .background(DesignColor.surfaceSunken, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Wolfram

struct WolframWidgetContentView: View {
    var onDelete: () -> Void

    @AppStorage("wolframAlphaAppID") private var wolframAppID = ""
    @State private var expression = ""

    var body: some View {
        WidgetCard(title: "Wolfram Alpha", onDelete: onDelete) {
            VStack(alignment: .leading, spacing: DesignSpace.s2) {
                if wolframAppID.isEmpty {
                    Text("Aggiungi la tua chiave AppID nel Profilo per usare questo widget.")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColor.textTertiary)
                } else {
                    TextField("Espressione da risolvere", text: $expression)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(8)
                        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.sm))
                    Text("Risoluzione in arrivo — per ora la chiave è pronta ma il calcolo non è ancora collegato qui (usa la penna magica per risolvere cerchiando).")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignColor.textTertiary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
