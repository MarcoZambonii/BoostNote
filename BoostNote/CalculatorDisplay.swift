import SwiftUI

// Composizione della formula: l'espressione è una stringa grezza
// ("√(2+x^2)/3+log(1000)") e qui diventa una formula come si scrive a
// mano — radici col vinculum che si allunga sul radicando, esponenti
// sollevati, frazioni impilate, parentesi di funzione più tenui.
//
// È SwiftUI puro e non KaTeX in una WebView: il testo cambia a ogni tasto
// e un giro in JavaScript per battuta si sentirebbe.
//
// La grammatica è VOLUTAMENTE tollerante: mentre si digita l'espressione è
// quasi sempre incompleta ("3/" senza denominatore, "√(" senza radicando).
// Dove manca un pezzo compare una casella tratteggiata, che dice "qui
// manca qualcosa" invece di far sparire la riga finché non torna valida.
indirect enum MathNode {
    case text(String)
    // Operatore additivo/moltiplicativo: vuole aria attorno.
    case spaced(String)
    // Parentesi e virgole di una chiamata: più tenui del contenuto.
    case dim(String)
    case row([MathNode])
    case fraction(MathNode, MathNode)
    case superscripted(MathNode)
    case radical(MathNode, index: String?)
    case slot
    case caret
}

enum MathLayout {
    // `cursor` è la posizione del punto di scrittura, in caratteri.
    // Negativa (o fuori testo) quando il cursore non va mostrato: storico,
    // espressione risolta.
    static func nodes(from expression: String, cursor: Int = -1) -> MathNode {
        var builder = Builder(tokens: (try? CalcTokenizer.scan(expression)) ?? [],
                              length: expression.count,
                              cursor: cursor)
        let nodes = builder.parseRow(stopAt: [])
        return .row(nodes)
    }

    private static let symbolGlyphs: [String: String] = [
        "*": "×", "-": "−", "×": "×", "÷": "÷", "+": "+", "−": "−",
        "%": "%", "!": "!", ",": ", "
    ]
    private static let identifierGlyphs: [String: String] = [
        "pi": "π", "tau": "τ", "ans": "Ans"
    ]
    private static let spacedSymbols: Set<String> = ["+", "−", "-", "×", "*", "÷"]

    private struct Builder {
        let tokens: [(token: CalcToken, offset: Int)]
        let length: Int
        let cursor: Int
        var index = 0
        var placedCaret = false

        var current: CalcToken? { index < tokens.count ? tokens[index].token : nil }

        // Il cursore si disegna PRIMA del pezzo che comincia alla sua
        // destra: è così che si vede fra due caratteri invece che sopra.
        mutating func caret(at position: Int) -> MathNode? {
            guard !placedCaret, cursor == position else { return nil }
            placedCaret = true
            return .caret
        }

        // Un solo "atomo": il gruppo fra parentesi (che perde le
        // parentesi), la chiamata di funzione, o il singolo pezzo. È ciò
        // che finisce sotto una radice o dentro un esponente.
        mutating func parseGroup() -> MathNode {
            guard index < tokens.count else { return .slot }
            let entry = tokens[index]
            if entry.token == .symbol("(") {
                index += 1
                let inner = parseRow(stopAt: [")"])
                if current == .symbol(")") { index += 1 }
                return inner.isEmpty ? .slot : .row(inner)
            }
            if case .identifier = entry.token, index + 1 < tokens.count, tokens[index + 1].token == .symbol("(") {
                return parseCall()
            }
            index += 1
            return .text(glyph(for: entry.token))
        }

        mutating func parseCall() -> MathNode {
            guard case .identifier(let name) = tokens[index].token else { return .slot }
            index += 2 // nome e parentesi aperta
            var arguments: [[MathNode]] = [parseRow(stopAt: [")", ","])]
            while current == .symbol(",") {
                index += 1
                arguments.append(parseRow(stopAt: [")", ","]))
            }
            let closed = current == .symbol(")")
            if closed { index += 1 }

            let first = arguments.first.flatMap { $0.isEmpty ? nil : MathNode.row($0) } ?? .slot
            switch name {
            case "sqrt": return .radical(first, index: nil)
            case "cbrt": return .radical(first, index: "3")
            case "abs": return .row([.dim("|"), first, .dim("|")])
            default:
                var pieces: [MathNode] = [.text(name), .dim("(")]
                for (position, argument) in arguments.enumerated() {
                    if position > 0 { pieces.append(.dim(", ")) }
                    pieces.append(argument.isEmpty ? .slot : .row(argument))
                }
                if closed { pieces.append(.dim(")")) }
                return .row(pieces)
            }
        }

        mutating func parseRow(stopAt stops: [String]) -> [MathNode] {
            var nodes: [MathNode] = []
            while true {
                guard index < tokens.count else {
                    if let mark = caret(at: length) { nodes.append(mark) }
                    break
                }
                let entry = tokens[index]
                if case .symbol(let symbol) = entry.token, stops.contains(symbol) {
                    if let mark = caret(at: entry.offset) { nodes.append(mark) }
                    break
                }
                if let mark = caret(at: entry.offset) { nodes.append(mark) }

                if entry.token == .symbol("√") {
                    index += 1
                    nodes.append(.radical(parseGroup(), index: nil))
                    continue
                }
                if entry.token == .symbol("^") {
                    index += 1
                    nodes.append(.superscripted(parseGroup()))
                    continue
                }
                if entry.token == .symbol("/") {
                    // FRAZIONE IMPILATA, e solo da "/": il numeratore è
                    // l'ultimo pezzo scritto, non tutta la riga — in
                    // "2+3/4" sopra la linea va il 3. La divisione "÷"
                    // resta invece in linea, ed è una distinzione voluta.
                    index += 1
                    let numerator = nodes.popLast() ?? .slot
                    nodes.append(.fraction(numerator, parseGroup()))
                    continue
                }
                if entry.token == .symbol("(") {
                    index += 1
                    let inner = parseRow(stopAt: [")"])
                    let closed = current == .symbol(")")
                    if closed { index += 1 }
                    var pieces: [MathNode] = [.dim("("), inner.isEmpty ? .slot : .row(inner)]
                    // Parentesi non chiusa: si mostra com'è, senza
                    // chiuderla da soli.
                    if closed { pieces.append(.dim(")")) }
                    nodes.append(.row(pieces))
                    continue
                }
                if case .identifier = entry.token, index + 1 < tokens.count, tokens[index + 1].token == .symbol("(") {
                    nodes.append(parseCall())
                    continue
                }

                index += 1
                if case .symbol(let symbol) = entry.token, MathLayout.spacedSymbols.contains(symbol) {
                    nodes.append(.spaced(glyph(for: entry.token)))
                } else {
                    nodes.append(.text(glyph(for: entry.token)))
                }
            }
            return nodes
        }

        func glyph(for token: CalcToken) -> String {
            switch token {
            // Il decimale si scrive con la virgola, come su un compito.
            case .number(_, let raw): return raw.replacingOccurrences(of: ".", with: ",")
            case .identifier(let name): return MathLayout.identifierGlyphs[name] ?? name
            case .symbol(let symbol): return MathLayout.symbolGlyphs[symbol] ?? symbol
            }
        }
    }
}

// MARK: - Vista

// Il segno di radice: un tracciato che si allunga con l'altezza del
// radicando e si salda al vinculum (che è il bordo superiore del box del
// radicando). Il tratto NON si deforma con la scala perché la Path viene
// costruita già nelle proporzioni giuste e disegnata dopo.
private struct RadicalSign: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 12 * rect.width, y: rect.minY + y / 24 * rect.height)
        }
        var path = Path()
        path.move(to: point(0.8, 14.5))
        path.addLine(to: point(3.6, 14.5))
        path.addLine(to: point(6.8, 23.2))
        path.addLine(to: point(11.4, 0.5))
        return path
    }
}

// Vista RICORSIVA: ogni nodo istanzia altre MathDisplayView per i figli.
// Non può essere una funzione @ViewBuilder ricorsiva — il tipo opaco
// finirebbe per definirsi in termini di sé stesso e il compilatore la
// rifiuta — mentre un tipo nominale che si annida in sé è regolare.
struct MathDisplayView: View {
    let node: MathNode
    var size: CGFloat
    var color: Color = DesignColor.textPrimary
    var weight: Font.Weight = .light

    private func child(_ node: MathNode, _ scale: CGFloat = 1) -> MathDisplayView {
        MathDisplayView(node: node, size: size * scale, color: color, weight: weight)
    }

    private var font: Font {
        .system(size: size, weight: weight).monospacedDigit()
    }

    // L'indice della radice (∛) scala col corpo della formula: il
    // compositore è parametrico per natura, come DesignFont.readout.
    private var radicalIndexFont: Font {
        .system(size: size * 0.46, weight: weight)
    }

    var body: some View {
        switch node {
        case .text(let value):
            Text(value).font(font).foregroundStyle(color)

        case .spaced(let value):
            Text(value).font(font).foregroundStyle(color)
                .padding(.horizontal, size * 0.18)

        case .dim(let value):
            Text(value).font(font).foregroundStyle(color.opacity(0.55))

        case .row(let children):
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, item in
                    child(item)
                }
            }

        case .fraction(let numerator, let denominator):
            // La barra sta in OVERLAY, non come riga in mezzo alla pila:
            // dentro la pila un Rectangle porta con sé una larghezza
            // ideale sua, e con fixedSize la frazione finiva misurata su
            // quella invece che sui due termini. In overlay è larga
            // esattamente quanto il più largo dei due, come si scrive a
            // mano.
            VStack(spacing: size * 0.168 + 1) {
                child(numerator, 0.84)
                child(denominator, 0.84)
            }
            .overlay {
                Rectangle().fill(color).frame(height: 1)
            }
            .padding(.horizontal, 3)

        case .superscripted(let exponent):
            child(exponent, 0.64)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                .offset(y: -size * 0.28)
                .padding(.leading, 1)

        case .radical(let inner, let index):
            HStack(spacing: 0) {
                if let index {
                    Text(index)
                        .font(radicalIndexFont)
                        .foregroundStyle(color)
                        .padding(.trailing, -size * 0.28)
                        .offset(y: size * 0.1)
                }
                RadicalSign()
                    .stroke(color, style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.52)
                child(inner)
                    .padding(.init(top: size * 0.16, leading: size * 0.06, bottom: size * 0.02, trailing: size * 0.2))
                    .overlay(alignment: .top) {
                        Rectangle().fill(color).frame(height: 1)
                    }
            }
            .fixedSize()
            .padding(.horizontal, 1)

        case .slot:
            RoundedRectangle(cornerRadius: DesignRadius.sm)
                .strokeBorder(DesignColor.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(width: size * 0.62, height: size * 0.62)
                .padding(.horizontal, 1)

        case .caret:
            RoundedRectangle(cornerRadius: DesignRadius.sm)
                .fill(DesignColor.brandPrimary)
                .frame(width: 2)
                .frame(minHeight: size)
                .padding(.horizontal, 1)
        }
    }
}
