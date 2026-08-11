import SwiftUI

// Contenuto della calcolatrice, pensato per vivere nel pannello laterale
// della nota (non più un foglio modale a sé).
struct CalculatorContentView: View {
    @State private var display = "0"
    @State private var accumulator: Double?
    @State private var pendingOperation: String?
    @State private var shouldResetDisplay = false

    private let rows: [[String]] = [
        ["C", "±", "%", "÷"],
        ["7", "8", "9", "×"],
        ["4", "5", "6", "−"],
        ["1", "2", "3", "+"],
        ["0", ".", "="]
    ]

    var body: some View {
        VStack(spacing: DesignSpace.s4) {
            Text(display)
                .font(.system(size: 48, weight: .light, design: .rounded))
                .foregroundStyle(DesignColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal)
                .lineLimit(1)
                .minimumScaleFactor(0.4)

            VStack(spacing: DesignSpace.s2) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: DesignSpace.s2) {
                        ForEach(row, id: \.self) { key in
                            Button {
                                tap(key)
                            } label: {
                                Text(key)
                                    .font(.system(size: 22, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 60)
                                    .foregroundStyle(isOperator(key) ? .white : DesignColor.textPrimary)
                                    .background(
                                        isOperator(key) ? DesignColor.brandPrimary : DesignColor.surfaceSunken,
                                        in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                                    )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            Spacer()
        }
        .padding(.top)
    }

    private func isOperator(_ key: String) -> Bool {
        ["÷", "×", "−", "+", "="].contains(key)
    }

    private func tap(_ key: String) {
        switch key {
        case "C":
            display = "0"; accumulator = nil; pendingOperation = nil; shouldResetDisplay = false
        case "±":
            if let value = Double(display) { display = format(value * -1) }
        case "%":
            if let value = Double(display) { display = format(value / 100) }
        case "÷", "×", "−", "+":
            accumulator = Double(display)
            pendingOperation = key
            shouldResetDisplay = true
        case "=":
            guard let accumulator, let op = pendingOperation, let current = Double(display) else { return }
            display = format(apply(op, accumulator, current))
            self.accumulator = nil
            pendingOperation = nil
            shouldResetDisplay = true
        case ".":
            if shouldResetDisplay { display = "0"; shouldResetDisplay = false }
            if !display.contains(".") { display += "." }
        default:
            if shouldResetDisplay || display == "0" {
                display = key
                shouldResetDisplay = false
            } else {
                display += key
            }
        }
    }

    private func apply(_ op: String, _ a: Double, _ b: Double) -> Double {
        switch op {
        case "÷": return b == 0 ? .nan : a / b
        case "×": return a * b
        case "−": return a - b
        case "+": return a + b
        default: return b
        }
    }

    private func format(_ value: Double) -> String {
        if value.isNaN { return "Errore" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.6g", value)
    }
}
