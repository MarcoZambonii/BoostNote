import SwiftUI

// Calcolatrice scientifica del pannello laterale della nota.
//
// Due scelte governano tutto il resto, e vengono dal design.
//
// 1. Il display mostra l'INPUT composto come formula — radici col
//    vinculum, esponenti sollevati, frazioni impilate — e NON il risultato
//    mentre si scrive: il risultato arriva solo con "=". Serve a poter
//    rileggere quello che si sta scrivendo, che su una riga di testo
//    grezzo ("√(2+x^2)/3") non si controlla a colpo d'occhio.
// 2. L'estetica non pesa: nessun tasto scuro, un solo colore d'accento, e
//    l'INCHIOSTRO a dire il ruolo del tasto invece della faccia — cifra
//    nera, operatore blu, controllo grigio.
//
// I conti li fa CalculatorEngine, che non va riscritto; la composizione
// della formula sta in CalculatorDisplay.
struct CalculatorContentView: View {
    @State private var expression = ""
    // Posizione del punto di scrittura, in caratteri: sempre su un confine
    // di token, perché le frecce si muovono di un token per volta.
    @State private var cursor = 0
    @State private var isSecond = false
    @State private var angleMode: AngleMode = .radians
    @State private var showsExact = false
    @State private var solved: Solved?
    @State private var errorMessage: String?
    @State private var answer: Double?
    @State private var history: [Entry] = []
    @State private var variables: [String: Double] = [:]
    @State private var panel: Panel?

    private struct Solved {
        var expression: String
        var value: Double
        var text: String
        var exact: String?
    }

    private struct Entry: Identifiable {
        let id = UUID()
        var input: String
        var output: String
    }

    private enum Panel: String { case functions, history, variables }

    private var evaluator: CalcEvaluator {
        CalcEvaluator(angleMode: angleMode, variables: variables, previous: answer)
    }

    // I confini di token dell'espressione: il cursore vive solo qui, così
    // una freccia non spezza mai "sin" a metà.
    private var bounds: [Int] {
        var positions: Set<Int> = [0, expression.count]
        for entry in (try? CalcTokenizer.scan(expression)) ?? [] {
            positions.insert(entry.offset)
            positions.insert(entry.offset + entry.token.length)
        }
        return positions.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            screen
            cursorRow
            hairline
            block(Self.functionRows, height: 32)
            block(Self.numberRows, height: 40)
            hairline
            toolbar
            panelContent
        }
        .padding(10)
        .background(DesignColor.surfacePage, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
    }

    private var hairline: some View {
        Rectangle().fill(DesignColor.borderSubtle).frame(height: 1)
    }

    // MARK: - Display

    private var screen: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(angleMode.label)
                    .font(.system(size: 9.5, weight: .bold)).tracking(1)
                    .foregroundStyle(DesignColor.textTertiary)
                if showsExact {
                    Text("ESATTO")
                        .font(.system(size: 9.5, weight: .bold)).tracking(1)
                        .foregroundStyle(DesignColor.brandPrimary)
                }
                Spacer(minLength: 0)
                Text(memoryHint)
                    .font(.system(size: 9.5, weight: .medium)).tracking(0.4)
                    .foregroundStyle(DesignColor.textTertiary)
            }
            .frame(minHeight: 13)

            if let solved {
                HStack(spacing: 0) {
                    MathDisplayView(node: MathLayout.nodes(from: solved.expression),
                                    size: 13, color: DesignColor.textTertiary, weight: .regular)
                    Text(" = ")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignColor.textTertiary)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 17)

                Text(showsExact ? (solved.exact ?? solved.text) : solved.text)
                    .font(.system(size: 34, weight: .ultraLight).monospacedDigit())
                    .foregroundStyle(DesignColor.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    Group {
                        if expression.isEmpty {
                            Text("scrivi un'espressione, poi premi =")
                                .font(.system(size: 14))
                                .foregroundStyle(DesignColor.textTertiary)
                        } else {
                            MathDisplayView(node: MathLayout.nodes(from: expression, cursor: cursor), size: 26)
                        }
                    }
                    .frame(minHeight: 44, alignment: .leading)
                }
                .frame(height: 48)
                .defaultScrollAnchor(.trailing)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12.5))
                    .foregroundStyle(DesignColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.init(top: 6, leading: 6, bottom: 14, trailing: 6))
    }

    private var memoryHint: String {
        var pieces: [String] = []
        if let answer { pieces.append("Ans " + CalcFormatter.string(answer)) }
        if !variables.isEmpty { pieces.append("\(variables.count) var") }
        return pieces.joined(separator: " · ")
    }

    // Riga del cursore: a sinistra dice a cosa servono le frecce, e nello
    // stato risolto diventa la via per ripartire dal risultato.
    private var cursorRow: some View {
        HStack(spacing: 6) {
            if solved != nil {
                Button("Continua dal risultato") { continueFromResult() }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DesignColor.brandPrimary)
                    .buttonStyle(.plain)
            } else {
                Text("cursore")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DesignColor.textTertiary)
            }
            Spacer(minLength: 0)
            arrow("chevron.left") { moveCursor(-1) }
            arrow("chevron.right") { moveCursor(1) }
        }
    }

    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignColor.brandPrimary)
                .frame(width: 40, height: 30)
                .background(DesignColor.surfacePage, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                        .strokeBorder(DesignColor.borderDefault, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tastiera

    private struct Key {
        var label: String
        var action: String
        var secondLabel: String?
        var secondAction: String?
        var role: Role = .function
        // Il ruolo decide l'inchiostro, non la faccia: le facce sono due
        // (tenue per chi inserisce testo, bianca con filo per chi agisce).
        enum Role { case function, mode, digit, operation, control, equals }
    }

    private static let functionRows: [[Key]] = [
        [
            Key(label: "2nd", action: "#second", role: .mode),
            Key(label: "a/b", action: "/", secondLabel: "%", secondAction: "%"),
            Key(label: "√", action: "√(", secondLabel: "∛", secondAction: "cbrt("),
            Key(label: "x²", action: "^2", secondLabel: "x⁻¹", secondAction: "^(-1)"),
            Key(label: "xʸ", action: "^", secondLabel: "ⁿ√", secondAction: "^(1/")
        ],
        [
            Key(label: "log", action: "log(", secondLabel: "10ˣ", secondAction: "10^"),
            Key(label: "ln", action: "ln(", secondLabel: "eˣ", secondAction: "exp("),
            Key(label: "(", action: "(", secondLabel: "|x|", secondAction: "abs("),
            Key(label: ")", action: ")", secondLabel: ",", secondAction: ","),
            Key(label: "S⇔D", action: "#form", role: .mode)
        ],
        [
            Key(label: "sin", action: "sin(", secondLabel: "sin⁻¹", secondAction: "asin("),
            Key(label: "cos", action: "cos(", secondLabel: "cos⁻¹", secondAction: "acos("),
            Key(label: "tan", action: "tan(", secondLabel: "tan⁻¹", secondAction: "atan("),
            Key(label: "π", action: "pi", secondLabel: "e", secondAction: "e"),
            Key(label: "#angle", action: "#angle", role: .mode)
        ]
    ]

    private static let numberRows: [[Key]] = [
        [
            Key(label: "7", action: "7", role: .digit), Key(label: "8", action: "8", role: .digit),
            Key(label: "9", action: "9", role: .digit),
            Key(label: "Cancella", action: "#back", role: .control), Key(label: "AC", action: "#clear", role: .control)
        ],
        [
            Key(label: "4", action: "4", role: .digit), Key(label: "5", action: "5", role: .digit),
            Key(label: "6", action: "6", role: .digit),
            Key(label: "×", action: "×", role: .operation), Key(label: "÷", action: "÷", role: .operation)
        ],
        [
            Key(label: "1", action: "1", role: .digit), Key(label: "2", action: "2", role: .digit),
            Key(label: "3", action: "3", role: .digit),
            Key(label: "+", action: "+", role: .operation), Key(label: "−", action: "−", role: .operation)
        ],
        [
            Key(label: "0", action: "0", role: .digit), Key(label: ",", action: ".", role: .digit),
            Key(label: "x!", action: "!", role: .digit),
            Key(label: "Ans", action: "ans", role: .operation), Key(label: "=", action: "#equals", role: .equals)
        ]
    ]

    private func block(_ rows: [[Key]], height: CGFloat) -> some View {
        VStack(spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, key in
                        keyButton(key, height: height)
                    }
                }
            }
        }
    }

    private func keyButton(_ key: Key, height: CGFloat) -> some View {
        let showsSecond = isSecond && key.secondLabel != nil
        let isLit = (key.action == "#second" && isSecond) || (key.action == "#form" && showsExact)
        let label = key.action == "#angle" ? angleMode.label : (showsSecond ? (key.secondLabel ?? key.label) : key.label)
        let ink = inkColor(for: key, showsSecond: showsSecond, lit: isLit)

        return Button {
            tap(showsSecond ? (key.secondAction ?? key.action) : key.action)
        } label: {
            Group {
                // Il tasto frazione non porta la scritta "a/b" ma il
                // glifo: due lettere impilate e la barra, che è quello che
                // il tasto produce.
                // Il glifo al posto della parola: "DEL" costringe a
                // leggere, il simbolo di cancellazione si riconosce.
                if key.action == "#back" {
                    Image(systemName: "delete.left")
                        .font(.system(size: 15, weight: .medium))
                } else if key.action == "/" && !showsSecond {
                    VStack(spacing: 1.5) {
                        Text("a").italic()
                        Rectangle().fill(ink).frame(width: 11, height: 1)
                        Text("b").italic()
                    }
                    .font(.system(size: 10, weight: .medium))
                } else {
                    Text(label)
                        .font(.system(size: fontSize(for: key, label: label), weight: fontWeight(for: key, lit: isLit)))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(faceColor(for: key, lit: isLit), in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                    .strokeBorder(hasBorder(key, lit: isLit) ? DesignColor.borderDefault : .clear, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.04), radius: 0, y: 1)
        }
        .buttonStyle(.plain)
    }

    private func faceColor(for key: Key, lit: Bool) -> Color {
        if lit { return DesignColor.brandPrimarySubtle }
        switch key.role {
        case .equals: return DesignColor.brandPrimary
        case .function: return DesignColor.surfaceSunken
        case .mode, .digit, .operation, .control: return DesignColor.surfacePage
        }
    }

    private func inkColor(for key: Key, showsSecond: Bool, lit: Bool) -> Color {
        if lit { return DesignColor.brandPrimary }
        if showsSecond { return DesignColor.brandPrimary }
        switch key.role {
        case .equals: return DesignColor.textOnBrand
        case .function: return DesignColor.textSecondary
        case .mode, .control: return DesignColor.textTertiary
        case .digit: return DesignColor.textPrimary
        case .operation: return DesignColor.brandPrimary
        }
    }

    private func hasBorder(_ key: Key, lit: Bool) -> Bool {
        guard !lit else { return false }
        switch key.role {
        case .function, .equals: return false
        case .mode, .digit, .operation, .control: return true
        }
    }

    private func fontSize(for key: Key, label: String) -> CGFloat {
        switch key.role {
        case .mode: return 11
        case .digit: return 18
        case .operation: return label.count > 2 ? 13 : 17
        case .control: return 12
        case .equals: return 18
        case .function: return 13
        }
    }

    private func fontWeight(for key: Key, lit: Bool) -> Font.Weight {
        if lit { return .semibold }
        switch key.role {
        case .mode: return .bold
        case .digit: return .regular
        case .operation: return .medium
        case .control, .equals: return .semibold
        case .function: return .medium
        }
    }

    // MARK: - Barra e pannelli

    private var toolbar: some View {
        HStack(spacing: 4) {
            tab(.functions, "ƒ(x) tutte le funzioni")
            tab(.history, "Cronologia")
            tab(.variables, "Variabili")
            Spacer(minLength: 0)
        }
    }

    private func tab(_ target: Panel, _ label: String) -> some View {
        Button {
            panel = panel == target ? nil : target
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(panel == target ? DesignColor.brandPrimary : DesignColor.textTertiary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(panel == target ? DesignColor.brandPrimarySubtle : .clear,
                            in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var panelContent: some View {
        switch panel {
        case .functions: catalogPanel
        case .history: historyPanel
        case .variables: variablesPanel
        case nil: EmptyView()
        }
    }

    private static let catalog: [(String, [String])] = [
        ("Trigonometria", ["sin(", "cos(", "tan(", "asin(", "acos(", "atan(", "sinh(", "cosh(", "tanh("]),
        ("Esponenziali", ["ln(", "log(", "log2(", "exp(", "sqrt(", "cbrt(", "^"]),
        ("Numeri", ["abs(", "round(", "floor(", "ceil(", "mod(", "hypot(", "!"]),
        ("Combinatoria", ["nCr(", "nPr("]),
        ("Costanti", ["pi", "e", "tau", "ans"])
    ]

    private var catalogPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.catalog, id: \.0) { group, items in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(group.uppercased())
                            .font(.system(size: 9.5, weight: .bold)).tracking(1)
                            .foregroundStyle(DesignColor.textTertiary)
                        FlowRow(items: items) { item in
                            Button { insert(item) } label: {
                                Text(item.replacingOccurrences(of: "(", with: ""))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(DesignColor.textPrimary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text("Moltiplicazione implicita ammessa (2π, 3(x+1)) · le variabili si salvano dal pannello Variabili e si richiamano toccandone il nome.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DesignColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .frame(maxHeight: 210)
    }

    private var historyPanel: some View {
        ScrollView {
            VStack(spacing: 0) {
                if history.isEmpty {
                    Text("Ancora nessun calcolo.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DesignColor.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                ForEach(Array(history.enumerated()), id: \.element.id) { position, entry in
                    Button { recall(entry.input) } label: {
                        HStack(spacing: 8) {
                            MathDisplayView(node: MathLayout.nodes(from: entry.input),
                                            size: 13, color: DesignColor.textSecondary, weight: .regular)
                            Spacer(minLength: 0)
                            Text(entry.output)
                                .font(.system(size: 13, weight: .medium).monospacedDigit())
                                .foregroundStyle(DesignColor.textPrimary)
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 2)
                        .overlay(alignment: .top) {
                            if position > 0 { Rectangle().fill(DesignColor.borderSubtle).frame(height: 1) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(maxHeight: 176)
    }

    // Niente tastiera alfabetica: si calcola, si preme "=", e si tocca un
    // nome per salvarci il risultato.
    private static let variableNames = ["A", "B", "x", "R"]

    private var variablesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Salva il risultato in")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignColor.textTertiary)
                ForEach(Self.variableNames, id: \.self) { name in
                    Button {
                        if let solved { variables[name] = solved.value }
                    } label: {
                        Text(name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(solved == nil ? DesignColor.textTertiary : DesignColor.brandPrimary)
                            .frame(minWidth: 24)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(DesignColor.surfacePage, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                                    .strokeBorder(DesignColor.borderDefault, lineWidth: 1)
                            }
                            .opacity(solved == nil ? 0.5 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(solved == nil)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 8)
            .padding(.horizontal, 2)

            if solved == nil {
                Text("Premi prima = : si salva il risultato mostrato.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DesignColor.textTertiary)
                    .padding(.bottom, 8)
                    .padding(.horizontal, 2)
            }

            ForEach(variables.keys.sorted(), id: \.self) { name in
                HStack(spacing: 8) {
                    Button { insert(name) } label: {
                        Text(name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(DesignColor.brandPrimary)
                            .frame(width: 34, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Text(CalcFormatter.string(variables[name] ?? 0))
                        .font(.system(size: 12.5).monospacedDigit())
                        .foregroundStyle(DesignColor.textPrimary)
                    Spacer(minLength: 0)
                    Button("rimuovi") { variables.removeValue(forKey: name) }
                        .font(.system(size: 11))
                        .foregroundStyle(DesignColor.textTertiary)
                        .buttonStyle(.plain)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 2)
                .overlay(alignment: .top) { Rectangle().fill(DesignColor.borderSubtle).frame(height: 1) }
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Comportamento

    private func tap(_ action: String) {
        // 2nd è momentaneo: si spegne al primo tasto premuto dopo.
        if action == "#second" { isSecond.toggle(); return }
        isSecond = false

        switch action {
        case "#angle":
            angleMode = angleMode == .degrees ? .radians : .degrees
            // Il risultato mostrato è stato calcolato con l'altro modo:
            // tenerlo lì sarebbe una bugia.
            solved = nil
        case "#form":
            showsExact.toggle()
        case "#left":
            moveCursor(-1)
        case "#right":
            moveCursor(1)
        case "#clear":
            expression = ""
            cursor = 0
            solved = nil
            errorMessage = nil
            showsExact = false
        case "#back":
            if solved != nil { solved = nil; return }
            let start = bounds.last { $0 < cursor } ?? 0
            let from = expression.index(expression.startIndex, offsetBy: start)
            let to = expression.index(expression.startIndex, offsetBy: cursor)
            expression.removeSubrange(from..<to)
            cursor = start
            errorMessage = nil
        case "#equals":
            evaluate()
        default:
            insert(action)
        }
    }

    private func insert(_ text: String) {
        // PARENTESI CHIUSA SUBITO. "√(" da solo lascia dentro la radice
        // per sempre: tutto quello che scrivi dopo finisce sotto il
        // vinculum, e non c'è modo di uscirne — nemmeno con la freccia,
        // che si muove sui pezzi che esistono. Chiudendola all'atto
        // dell'inserimento la via d'uscita c'è: il cursore resta dentro,
        // e "▶" scavalca la chiusa e ti riporta fuori.
        let opened = text.filter { $0 == "(" }.count - text.filter { $0 == ")" }.count
        let closers = String(repeating: ")", count: max(0, opened))
        let position = expression.index(expression.startIndex, offsetBy: min(cursor, expression.count))
        expression.insert(contentsOf: text + closers, at: position)
        // Il cursore si ferma dopo il testo VOLUTO, non dopo le chiuse
        // aggiunte da noi: si continua a scrivere dentro la funzione.
        cursor += text.count
        solved = nil
        errorMessage = nil
    }

    // Le frecce si spostano di un TOKEN, non di un carattere: dentro
    // "sin(" non c'è niente da fare fra la s e la i.
    private func moveCursor(_ direction: Int) {
        let stops = bounds
        if direction < 0 {
            cursor = stops.last { $0 < cursor } ?? 0
        } else {
            cursor = stops.first { $0 > cursor } ?? expression.count
        }
    }

    private func recall(_ text: String) {
        expression = text
        cursor = text.count
        solved = nil
        errorMessage = nil
    }

    private func continueFromResult() {
        guard let solved else { return }
        recall(CalcFormatter.string(solved.value))
    }

    private func evaluate() {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            let result = try evaluator.evaluate(trimmed)
            answer = result.value
            solved = Solved(expression: trimmed, value: result.value, text: result.text, exact: result.exact)
            history.insert(Entry(input: trimmed, output: result.text), at: 0)
            if history.count > 12 { history.removeLast(history.count - 12) }
            if let name = result.assigned { variables[name] = result.value }
            errorMessage = nil
        } catch {
            // L'errore è la cosa più utile che una calcolatrice possa
            // dire: "Non conosco pippo" invece di "Errore".
            errorMessage = (error as? CalcError)?.errorDescription ?? "Non riesco a calcolare questa espressione."
            solved = nil
        }
    }
}

// Righe che vanno a capo da sole: SwiftUI non ha un flow layout pronto e
// il catalogo delle funzioni ne ha bisogno.
private struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { ForEach(items, id: \.self, content: content) }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                    HStack(spacing: 4) { ForEach(chunk, id: \.self, content: content) }
                }
            }
        }
    }

    private var chunks: [[Item]] {
        stride(from: 0, to: items.count, by: 4).map {
            Array(items[$0..<min($0 + 4, items.count)])
        }
    }
}
