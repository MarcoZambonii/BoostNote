import Foundation

// Motore della calcolatrice scientifica: da una riga di testo a un numero.
//
// Analizzatore a discesa ricorsiva, non una macchina a stati che accumula
// un'operazione per volta. È la scelta che permette di scrivere
// "3(4+5)^2" per intero e vederlo risolto con le precedenze giuste,
// invece di dover battere i tasti nell'ordine in cui la macchina li vuole.

enum CalcError: LocalizedError, Equatable {
    case syntax(String)
    case unknown(String)
    case domain(String)

    var errorDescription: String? {
        switch self {
        case .syntax(let detail): detail
        case .unknown(let name): "Non conosco \"\(name)\""
        case .domain(let detail): detail
        }
    }
}

enum AngleMode: String, CaseIterable {
    case radians, degrees
    var label: String { self == .radians ? "RAD" : "DEG" }
}

struct CalcResult {
    var value: Double
    var text: String
    // Forma esatta, quando il numero ne ha una riconoscibile: "3/4",
    // "π/3", "2√3". nil quando c'è solo il decimale — ed è la stessa
    // condizione che spegne il tasto S⇔D.
    var exact: String?
    // Nome della variabile appena assegnata, se la riga era "x = ...".
    var assigned: String?
}

struct CalcEvaluator {
    var angleMode: AngleMode = .degrees
    var variables: [String: Double] = [:]
    // Il risultato precedente, richiamabile con "ans".
    var previous: Double?

    // "tau" è nel catalogo delle funzioni del pannello, quindi deve
    // esistere anche qui: un tasto che inserisce un nome sconosciuto è
    // peggio di un tasto assente.
    static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E, "tau": 2 * .pi]

    func evaluate(_ input: String) throws -> CalcResult {
        var parser = Parser(tokens: try CalcTokenizer.tokens(of: input), evaluator: self)
        let outcome = try parser.parseLine()
        return CalcResult(
            value: outcome.value,
            text: CalcFormatter.string(outcome.value),
            exact: CalcExact.form(of: outcome.value),
            assigned: outcome.assigned
        )
    }
}

// MARK: - Analisi lessicale

enum CalcToken: Equatable {
    // Quanto testo occupa: serve al cursore del display, che si muove di
    // un token per volta e deve sapere dove finisce.
    var length: Int {
        switch self {
        case .number(_, let raw): raw.count
        case .identifier(let name): name.count
        case .symbol(let symbol): symbol.count
        }
    }

    // Il valore E il testo originale. Il display mostra il secondo: chi
    // scrive "3." deve vedere "3.", non "3", e chi scrive "2e3" deve
    // vedere una potenza di dieci, non "2000".
    case number(Double, raw: String)
    case identifier(String)
    case symbol(String)
}

enum CalcTokenizer {
    static func tokens(of input: String) throws -> [CalcToken] {
        try scan(input).map(\.token)
    }

    // Come `tokens`, ma con la POSIZIONE di ogni pezzo nel testo
    // originale. Serve al display per sapere dove cade il cursore: senza
    // le posizioni, l'unico modo di disegnarlo sarebbe spezzare la
    // stringa in due e analizzare due metà rotte.
    static func scan(_ input: String) throws -> [(token: CalcToken, offset: Int)] {
        var tokens: [(CalcToken, Int)] = []
        let characters = Array(input)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace { index += 1; continue }
            let start = index

            if character.isNumber || (character == "." && index + 1 < characters.count && characters[index + 1].isNumber) {
                var literal = ""
                while index < characters.count, characters[index].isNumber || characters[index] == "." {
                    literal.append(characters[index]); index += 1
                }
                // "2e3" è notazione scientifica, "2e" è 2 per il numero di
                // Nepero: la "e" vale da esponente solo se dopo di lei
                // arrivano davvero delle cifre.
                if index < characters.count, characters[index] == "e" || characters[index] == "E" {
                    var lookahead = index + 1
                    if lookahead < characters.count, characters[lookahead] == "+" || characters[lookahead] == "-" { lookahead += 1 }
                    if lookahead < characters.count, characters[lookahead].isNumber {
                        literal.append("e"); index += 1
                        if characters[index] == "+" || characters[index] == "-" { literal.append(characters[index]); index += 1 }
                        while index < characters.count, characters[index].isNumber { literal.append(characters[index]); index += 1 }
                    }
                }
                guard let value = Double(literal) else { throw CalcError.syntax("Numero non valido: \(literal)") }
                tokens.append((.number(value, raw: literal), start))
                continue
            }

            if character.isLetter || character == "_" || character == "π" {
                var name = ""
                while index < characters.count,
                      characters[index].isLetter || characters[index].isNumber || characters[index] == "_" || characters[index] == "π" {
                    name.append(characters[index]); index += 1
                }
                tokens.append((.identifier(name), start))
                continue
            }

            tokens.append((.symbol(String(character)), index))
            index += 1
        }
        return tokens
    }
}

// MARK: - Analisi sintattica

private struct ParseOutcome {
    var value: Double
    var assigned: String?
}

private struct Parser {
    let tokens: [CalcToken]
    let evaluator: CalcEvaluator
    var index = 0

    var current: CalcToken? { index < tokens.count ? tokens[index] : nil }

    mutating func parseLine() throws -> ParseOutcome {
        guard !tokens.isEmpty else { throw CalcError.syntax("Espressione vuota") }

        // Assegnazione: "R = 220". Si riconosce solo se la riga COMINCIA
        // con un identificatore seguito da "=", altrimenti "2 = 2" e
        // simili verrebbero scambiati per definizioni.
        var assigned: String?
        if case .identifier(let name) = tokens[0], tokens.count > 1, tokens[1] == .symbol("=") {
            guard CalcEvaluator.constants[name] == nil, name != "ans" else {
                throw CalcError.syntax("\"\(name)\" è un nome riservato")
            }
            assigned = name
            index = 2
        }

        let value = try parseAdditive()
        guard index >= tokens.count else { throw CalcError.syntax("Non capisco la fine della riga") }
        return ParseOutcome(value: value, assigned: assigned)
    }

    mutating func parseAdditive() throws -> Double {
        var left = try parseMultiplicative()
        while let token = current, token == .symbol("+") || token == .symbol("-") || token == .symbol("−") {
            index += 1
            let right = try parseMultiplicative()
            left = token == .symbol("+") ? left + right : left - right
        }
        return left
    }

    mutating func parseMultiplicative() throws -> Double {
        var left = try parseImplicit()
        while let token = current {
            if token == .symbol("*") || token == .symbol("×") || token == .symbol("·") {
                index += 1
                left *= try parseImplicit()
            } else if token == .symbol("/") || token == .symbol("÷") || token == .symbol(":") {
                index += 1
                let right = try parseImplicit()
                guard right != 0 else { throw CalcError.domain("Divisione per zero") }
                left /= right
            } else {
                break
            }
        }
        return left
    }

    // MOLTIPLICAZIONE IMPLICITA, a un livello suo. È ciò che fa funzionare
    // "2π" e "3(x+1)", e sta sopra la divisione di proposito: chi scrive
    // "1/2π" intende 1/(2π), come sulla carta.
    mutating func parseImplicit() throws -> Double {
        var left = try parseUnary()
        while let token = current, startsPrimary(token) {
            left *= try parseUnary()
        }
        return left
    }

    func startsPrimary(_ token: CalcToken) -> Bool {
        switch token {
        case .number, .identifier: return true
        case .symbol(let symbol): return symbol == "(" || symbol == "√"
        }
    }

    mutating func parseUnary() throws -> Double {
        if let token = current, token == .symbol("-") || token == .symbol("−") {
            index += 1
            return -(try parseUnary())
        }
        if current == .symbol("+") { index += 1; return try parseUnary() }
        return try parsePower()
    }

    mutating func parsePower() throws -> Double {
        let base = try parsePostfix()
        guard current == .symbol("^") else { return base }
        index += 1
        // Associativa a destra: 2^3^2 è 2^9, non 8^2.
        let exponent = try parseUnary()
        let result = pow(base, exponent)
        guard result.isFinite else { throw CalcError.domain("Potenza non calcolabile") }
        return result
    }

    mutating func parsePostfix() throws -> Double {
        var value = try parsePrimary()
        while let token = current {
            if token == .symbol("!") {
                index += 1
                let rounded = value.rounded()
                guard abs(value - rounded) < 1e-9, rounded >= 0, rounded <= 170 else {
                    throw CalcError.domain("Il fattoriale vuole un intero fra 0 e 170")
                }
                var product = 1.0
                var step = 2.0
                while step <= rounded { product *= step; step += 1 }
                value = product
            } else if token == .symbol("%") {
                index += 1
                value /= 100
            } else {
                break
            }
        }
        return value
    }

    mutating func parsePrimary() throws -> Double {
        guard let token = current else { throw CalcError.syntax("Manca un valore") }
        switch token {
        case .number(let value, _):
            index += 1
            return value

        case .symbol("("):
            index += 1
            let value = try parseAdditive()
            guard current == .symbol(")") else { throw CalcError.syntax("Manca una parentesi chiusa") }
            index += 1
            return value

        // Il simbolo, non solo "sqrt(": così un risultato esatto come
        // "√2" può essere rimandato dentro senza riscriverlo.
        case .symbol("√"):
            index += 1
            let value = try parseUnary()
            guard value >= 0 else { throw CalcError.domain("La radice vuole un valore non negativo") }
            return value.squareRoot()

        case .identifier(let name):
            index += 1
            if current == .symbol("(") {
                index += 1
                var arguments: [Double] = []
                if current != .symbol(")") {
                    arguments.append(try parseAdditive())
                    while current == .symbol(",") || current == .symbol(";") {
                        index += 1
                        arguments.append(try parseAdditive())
                    }
                }
                guard current == .symbol(")") else { throw CalcError.syntax("Manca una parentesi chiusa dopo \(name)") }
                index += 1
                return try CalcFunctions.apply(name, arguments, angleMode: evaluator.angleMode)
            }
            if name == "ans" {
                guard let previous = evaluator.previous else { throw CalcError.unknown("ans") }
                return previous
            }
            if let variable = evaluator.variables[name] { return variable }
            if let constant = CalcEvaluator.constants[name] { return constant }
            throw CalcError.unknown(name)

        case .symbol(let symbol):
            throw CalcError.syntax("Non mi aspettavo \"\(symbol)\"")
        }
    }
}

// MARK: - Funzioni

enum CalcFunctions {
    static func apply(_ name: String, _ arguments: [Double], angleMode: AngleMode) throws -> Double {
        func one() throws -> Double {
            guard arguments.count == 1 else { throw CalcError.syntax("\(name) vuole un argomento") }
            return arguments[0]
        }
        func two() throws -> (Double, Double) {
            guard arguments.count == 2 else { throw CalcError.syntax("\(name) vuole due argomenti") }
            return (arguments[0], arguments[1])
        }
        // In gradi la conversione avviene QUI e solo qui: dentro il motore
        // gli angoli sono sempre radianti.
        func toRadians(_ value: Double) -> Double { angleMode == .degrees ? value * .pi / 180 : value }
        func fromRadians(_ value: Double) -> Double { angleMode == .degrees ? value * 180 / .pi : value }
        func positive(_ value: Double) throws -> Double {
            guard value > 0 else { throw CalcError.domain("Il logaritmo vuole un valore positivo") }
            return value
        }

        switch name {
        case "sin": return sin(toRadians(try one()))
        case "cos": return cos(toRadians(try one()))
        case "tan": return tan(toRadians(try one()))
        case "asin":
            let value = try one()
            guard abs(value) <= 1 else { throw CalcError.domain("asin vuole un valore fra -1 e 1") }
            return fromRadians(asin(value))
        case "acos":
            let value = try one()
            guard abs(value) <= 1 else { throw CalcError.domain("acos vuole un valore fra -1 e 1") }
            return fromRadians(acos(value))
        case "atan": return fromRadians(atan(try one()))
        case "sinh": return sinh(try one())
        case "cosh": return cosh(try one())
        case "tanh": return tanh(try one())
        case "ln": return Foundation.log(try positive(try one()))
        case "log", "log10": return Foundation.log10(try positive(try one()))
        case "log2": return Foundation.log2(try positive(try one()))
        case "exp": return Foundation.exp(try one())
        case "sqrt":
            let value = try one()
            guard value >= 0 else { throw CalcError.domain("La radice vuole un valore non negativo") }
            return value.squareRoot()
        case "cbrt": return Foundation.cbrt(try one())
        case "abs": return Swift.abs(try one())
        case "round": return (try one()).rounded()
        case "floor": return (try one()).rounded(.down)
        case "ceil": return (try one()).rounded(.up)
        case "min": let (a, b) = try two(); return Swift.min(a, b)
        case "max": let (a, b) = try two(); return Swift.max(a, b)
        case "hypot": let (a, b) = try two(); return Foundation.hypot(a, b)
        case "mod":
            let (a, b) = try two()
            guard b != 0 else { throw CalcError.domain("mod con divisore nullo") }
            return a.truncatingRemainder(dividingBy: b)
        case "nCr", "nPr":
            let (n, r) = try two()
            guard n >= r, r >= 0, n == n.rounded(), r == r.rounded(), n <= 170 else {
                throw CalcError.domain("\(name) vuole due interi con n ≥ r ≥ 0")
            }
            func factorial(_ value: Double) -> Double {
                var product = 1.0
                var step = 2.0
                while step <= value { product *= step; step += 1 }
                return product
            }
            let arrangements = factorial(n) / factorial(n - r)
            return name == "nPr" ? arrangements : arrangements / factorial(r)
        default:
            throw CalcError.unknown(name + "()")
        }
    }
}

// MARK: - Formattazione

enum CalcFormatter {
    // Dieci cifre significative come una scientifica da tavolo, zeri
    // finali via, e notazione scientifica solo quando le cifre
    // diventerebbero illeggibili.
    static func string(_ value: Double) -> String {
        if value == 0 { return "0" }
        guard value.isFinite else { return "—" }
        let magnitude = abs(value)
        if magnitude >= 1e10 || magnitude < 1e-6 {
            let text = String(format: "%.9e", value)
            let parts = text.split(separator: "e")
            guard parts.count == 2 else { return text }
            return trimZeros(String(parts[0])) + "e" + String(Int(parts[1]) ?? 0)
        }
        if value == value.rounded(), magnitude < 1e15 { return String(Int64(value)) }
        return trimZeros(String(format: "%.10f", value))
    }

    private static func trimZeros(_ text: String) -> String {
        guard text.contains(".") else { return text }
        var result = text
        while result.hasSuffix("0") { result.removeLast() }
        if result.hasSuffix(".") { result.removeLast() }
        return result
    }
}

// MARK: - Forma esatta (il tasto S⇔D)

// Riconosce la forma esatta di un risultato PARTENDO DAL NUMERO, senza
// algebra simbolica: il motore calcola in virgola mobile e qui si prova a
// riconoscere che 0.7853981... è π/4.
//
// Il compromesso è dichiarato: si riconosce, non si dimostra. La difesa
// contro i falsi riconoscimenti è duplice — denominatori piccoli e
// tolleranza RELATIVA stretta — perché dire "1/3" per un numero che 1/3
// non è sarebbe peggio che non dire niente. Quando il sospetto non regge,
// si restituisce nil e resta il decimale.
enum CalcExact {
    static func form(of value: Double) -> String? {
        guard value.isFinite, value != 0 else { return nil }

        // Frazione: 0.75 -> 3/4. Gli interi non producono forma esatta,
        // sarebbe identica al decimale.
        if let (numerator, denominator) = rational(value, maxDenominator: 9999), denominator != 1 {
            return "\(numerator)/\(denominator)"
        }
        // Multipli di π: 1.0471975... -> π/3.
        if let (numerator, denominator) = rational(value / .pi, maxDenominator: 99),
           abs(numerator) <= 99 {
            let sign = numerator < 0 ? "-" : ""
            let top = abs(numerator)
            let head = top == 1 ? "π" : "\(top)π"
            return denominator == 1 ? sign + head : sign + head + "/\(denominator)"
        }
        // Radici: 1.4142135... -> √2, 3.4641016... -> 2√3, e anche
        // 0.7071067... -> √2/2, che è il coseno di 45° e sarebbe un
        // peccato mancarlo. Il quadrato può essere una FRAZIONE: da p/q
        // si passa a √(pq)/q, che è la stessa cosa scritta senza radici
        // al denominatore.
        if value > 0, let (numerator, denominator) = rational(value * value, maxDenominator: 999),
           numerator > 0, numerator * denominator <= 100_000 {
            let (extracted, remainder) = extractSquare(numerator * denominator)
            guard remainder > 1 else { return nil }
            let divisor = greatestCommonDivisor(extracted, denominator)
            let coefficient = extracted / divisor
            let bottom = denominator / divisor
            let head = coefficient == 1 ? "√\(remainder)" : "\(coefficient)√\(remainder)"
            return bottom == 1 ? head : head + "/\(bottom)"
        }
        return nil
    }

    // Frazioni continue: il modo classico di trovare la frazione più
    // semplice che approssima un numero entro una tolleranza.
    private static func rational(_ value: Double, maxDenominator: Int) -> (Int, Int)? {
        guard value.isFinite, abs(value) < 1e9 else { return nil }
        let negative = value < 0
        var remainder = abs(value)
        let target = remainder
        var previousNumerator = 0, numerator = 1
        var previousDenominator = 1, denominator = 0

        for _ in 0..<32 {
            let whole = remainder.rounded(.down)
            let wholeInt = Int(whole)
            (previousNumerator, numerator) = (numerator, wholeInt * numerator + previousNumerator)
            (previousDenominator, denominator) = (denominator, wholeInt * denominator + previousDenominator)
            guard denominator != 0, denominator <= maxDenominator else { return nil }
            let approximation = Double(numerator) / Double(denominator)
            if abs(target - approximation) <= 1e-11 * Swift.max(1, target) {
                return (negative ? -numerator : numerator, denominator)
            }
            let fraction = remainder - whole
            guard fraction > 1e-12 else { return nil }
            remainder = 1 / fraction
        }
        return nil
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var first = Swift.abs(a), second = Swift.abs(b)
        while second != 0 { (first, second) = (second, first % second) }
        return Swift.max(first, 1)
    }

    // 12 -> (2, 3), cioè √12 = 2√3.
    private static func extractSquare(_ value: Int) -> (Int, Int) {
        var coefficient = 1
        var remainder = value
        var factor = 2
        while factor * factor <= remainder {
            let square = factor * factor
            while remainder % square == 0 {
                remainder /= square
                coefficient *= factor
            }
            factor += 1
        }
        return (coefficient, remainder)
    }
}
