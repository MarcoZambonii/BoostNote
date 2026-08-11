import Foundation

// Valutatore minimale di espressioni matematiche in una variabile "x"
// (per lo strumento Grafici). Supporta + - * / ^, parentesi, funzioni
// comuni e le costanti pi/e. Niente dipendenze esterne.
enum MathExpressionError: Error {
    case invalidExpression
}

struct MathExpression {
    private enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case symbol(Character)
    }

    private let tokens: [Token]

    init(_ expression: String) throws {
        tokens = try Self.tokenize(expression)
    }

    func evaluate(x: Double) throws -> Double {
        var index = 0
        let value = try Self.parseExpression(tokens, &index, x)
        guard index == tokens.count else { throw MathExpressionError.invalidExpression }
        return value
    }

    private static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        var chars = Array(text.lowercased().replacingOccurrences(of: " ", with: ""))
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isNumber || c == "." {
                var numStr = ""
                while i < chars.count, chars[i].isNumber || chars[i] == "." {
                    numStr.append(chars[i])
                    i += 1
                }
                guard let value = Double(numStr) else { throw MathExpressionError.invalidExpression }
                tokens.append(.number(value))
            } else if c.isLetter {
                var name = ""
                while i < chars.count, chars[i].isLetter {
                    name.append(chars[i])
                    i += 1
                }
                tokens.append(.identifier(name))
            } else if "+-*/^()".contains(c) {
                tokens.append(.symbol(c))
                i += 1
            } else {
                throw MathExpressionError.invalidExpression
            }
        }
        _ = chars
        return tokens
    }

    private static func parseExpression(_ tokens: [Token], _ i: inout Int, _ x: Double) throws -> Double {
        var value = try parseTerm(tokens, &i, x)
        while i < tokens.count, tokens[i] == .symbol("+") || tokens[i] == .symbol("-") {
            let op = tokens[i]; i += 1
            let rhs = try parseTerm(tokens, &i, x)
            value = (op == .symbol("+")) ? value + rhs : value - rhs
        }
        return value
    }

    private static func parseTerm(_ tokens: [Token], _ i: inout Int, _ x: Double) throws -> Double {
        var value = try parsePower(tokens, &i, x)
        while i < tokens.count, tokens[i] == .symbol("*") || tokens[i] == .symbol("/") {
            let op = tokens[i]; i += 1
            let rhs = try parsePower(tokens, &i, x)
            value = (op == .symbol("*")) ? value * rhs : value / rhs
        }
        return value
    }

    private static func parsePower(_ tokens: [Token], _ i: inout Int, _ x: Double) throws -> Double {
        let base = try parseUnary(tokens, &i, x)
        if i < tokens.count, tokens[i] == .symbol("^") {
            i += 1
            let exponent = try parsePower(tokens, &i, x)
            return pow(base, exponent)
        }
        return base
    }

    private static func parseUnary(_ tokens: [Token], _ i: inout Int, _ x: Double) throws -> Double {
        if i < tokens.count, tokens[i] == .symbol("-") {
            i += 1
            return -(try parseUnary(tokens, &i, x))
        }
        return try parseAtom(tokens, &i, x)
    }

    private static func parseAtom(_ tokens: [Token], _ i: inout Int, _ x: Double) throws -> Double {
        guard i < tokens.count else { throw MathExpressionError.invalidExpression }
        switch tokens[i] {
        case .number(let v):
            i += 1
            return v
        case .symbol("("):
            i += 1
            let value = try parseExpression(tokens, &i, x)
            guard i < tokens.count, tokens[i] == .symbol(")") else { throw MathExpressionError.invalidExpression }
            i += 1
            return value
        case .identifier(let name):
            i += 1
            if i < tokens.count, tokens[i] == .symbol("(") {
                i += 1
                let arg = try parseExpression(tokens, &i, x)
                guard i < tokens.count, tokens[i] == .symbol(")") else { throw MathExpressionError.invalidExpression }
                i += 1
                return try apply(function: name, arg)
            }
            switch name {
            case "x": return x
            case "pi": return .pi
            case "e": return M_E
            default: throw MathExpressionError.invalidExpression
            }
        default:
            throw MathExpressionError.invalidExpression
        }
    }

    private static func apply(function: String, _ arg: Double) throws -> Double {
        switch function {
        case "sin": return sin(arg)
        case "cos": return cos(arg)
        case "tan": return tan(arg)
        case "sqrt": return sqrt(arg)
        case "abs": return abs(arg)
        case "log": return log10(arg)
        case "ln": return log(arg)
        default: throw MathExpressionError.invalidExpression
        }
    }
}
