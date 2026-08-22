import SwiftUI

// Pannello "Strumenti": si apre a cascata ancorato al pulsante, non come
// sheet a schermo intero — lista a sinistra (ricerca + icona/nome),
// anteprima + descrizione a destra. Lo stesso pattern master/detail va
// tenuto per gli altri picker "a catalogo" dell'app.
struct ToolsPickerSheet: View {
    var onSelect: (NoteTool) -> Void

    @State private var query = ""
    @State private var selectedTool: NoteTool = NoteTool.allCases[0]

    private var filteredTools: [NoteTool] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return NoteTool.allCases }
        return NoteTool.allCases.filter { $0.label.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        if DeviceLayout.isPhone {
            // Su iPhone non c'è spazio per master/detail affiancati: solo
            // l'elenco, e il tocco su una riga apre subito lo strumento
            // (la descrizione sta sotto il nome, al posto dell'anteprima).
            phoneList
                .background(DesignColor.surfacePage)
        } else {
            HStack(spacing: 0) {
                list
                    .frame(width: 240)
                Divider()
                detail(for: selectedTool)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 680, height: 460)
            .background(DesignColor.surfacePage)
        }
    }

    private var phoneList: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSpace.s2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignColor.textTertiary)
                TextField("Cerca strumenti", text: $query)
                    .font(.system(size: 14))
                    .textFieldStyle(.plain)
            }
            .padding(DesignSpace.s3)
            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
            .padding(DesignSpace.s3)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filteredTools) { tool in
                        Button {
                            onSelect(tool)
                        } label: {
                            HStack(spacing: DesignSpace.s3) {
                                Image(systemName: tool.systemImage)
                                    .font(.system(size: 16))
                                    .foregroundStyle(DesignColor.brandPrimary)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.label)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(DesignColor.textPrimary)
                                    Text(tool.toolDescription)
                                        .font(.system(size: 12))
                                        .foregroundStyle(DesignColor.textTertiary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DesignColor.textTertiary)
                            }
                            .padding(.horizontal, DesignSpace.s3)
                            .padding(.vertical, DesignSpace.s2 + 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DesignSpace.s2)
                .padding(.bottom, DesignSpace.s3)
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSpace.s2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignColor.textTertiary)
                TextField("Cerca strumenti", text: $query)
                    .font(.system(size: 14))
                    .textFieldStyle(.plain)
            }
            .padding(DesignSpace.s3)
            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
            .padding(DesignSpace.s3)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filteredTools) { tool in
                        Button {
                            selectedTool = tool
                        } label: {
                            HStack(spacing: DesignSpace.s3) {
                                Image(systemName: tool.systemImage)
                                    .font(.system(size: 15))
                                    .foregroundStyle(selectedTool == tool ? DesignColor.brandPrimary : DesignColor.textSecondary)
                                    .frame(width: 22)
                                Text(tool.label)
                                    .font(.system(size: 14, weight: selectedTool == tool ? .semibold : .medium))
                                    .foregroundStyle(selectedTool == tool ? DesignColor.brandPrimary : DesignColor.textPrimary)
                                Spacer()
                            }
                            .padding(.horizontal, DesignSpace.s3)
                            .padding(.vertical, DesignSpace.s2 + 2)
                            .background(
                                selectedTool == tool ? DesignColor.brandPrimarySubtle : Color.clear,
                                in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DesignSpace.s2)
                .padding(.bottom, DesignSpace.s3)
            }
        }
        .background(DesignColor.surfaceSunken)
    }

    private func detail(for tool: NoteTool) -> some View {
        VStack(spacing: DesignSpace.s5) {
            Spacer(minLength: 0)

            Image(systemName: tool.systemImage)
                .font(.system(size: 28))
                .foregroundStyle(DesignColor.brandPrimary)

            VStack(spacing: DesignSpace.s2) {
                Text(tool.label)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(DesignColor.textPrimary)
                Text(tool.toolDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(DesignColor.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            toolPreview(tool)
                .frame(width: 300, height: 160)
                .background(Color.white, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
                        .stroke(DesignColor.borderDefault, lineWidth: 1)
                )

            Spacer(minLength: 0)

            Button {
                onSelect(tool)
            } label: {
                Text("Apri nel pannello")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(DesignColor.brandPrimary, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(DesignSpace.s6)
    }

    // Mini illustrazioni statiche, in stile con i mock-up già usati
    // altrove nell'app (es. le card nota di Home), non screenshot veri.
    @ViewBuilder
    private func toolPreview(_ tool: NoteTool) -> some View {
        switch tool {
        case .pomodoro:
            VStack(spacing: DesignSpace.s2) {
                ZStack {
                    Circle().stroke(DesignColor.borderDefault, lineWidth: 4)
                    Circle().trim(from: 0, to: 0.7).stroke(DesignColor.brandPrimary, lineWidth: 4).rotationEffect(.degrees(-90))
                    Text("25:00").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(DesignColor.brandPrimary)
                }
                .frame(width: 64, height: 64)
                Text("Avvia").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, DesignSpace.s3).padding(.vertical, 4)
                    .background(DesignColor.brandPrimary, in: RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous))
            }

        case .todo:
            VStack(alignment: .leading, spacing: DesignSpace.s2) {
                ForEach(0..<3, id: \.self) { i in
                    HStack(spacing: 8) {
                        Image(systemName: i == 0 ? "checkmark.square.fill" : "square")
                            .foregroundStyle(i == 0 ? DesignColor.brandPrimary : DesignColor.textTertiary)
                        Rectangle().fill(DesignColor.borderDefault).frame(height: 6).frame(width: CGFloat(120 - i * 20))
                    }
                }
            }

        case .calculator:
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 6).fill(DesignColor.surfaceSunken).frame(height: 24)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(0..<8, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 6).fill(DesignColor.surfaceSunken).frame(height: 18)
                    }
                }
            }

        case .research:
            VStack(alignment: .leading, spacing: DesignSpace.s2) {
                HStack {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(DesignColor.textTertiary)
                    Rectangle().fill(DesignColor.borderDefault).frame(height: 6).frame(width: 100)
                }
                ForEach(0..<3, id: \.self) { i in
                    Rectangle().fill(DesignColor.surfaceSunken).frame(height: 14).frame(width: CGFloat(150 - i * 15))
                }
            }

        case .graphing:
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.move(to: CGPoint(x: size.width / 2, y: 0))
                path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                context.stroke(path, with: .color(DesignColor.borderDefault), lineWidth: 1)

                var curve = Path()
                curve.move(to: CGPoint(x: 0, y: size.height * 0.9))
                curve.addCurve(
                    to: CGPoint(x: size.width, y: size.height * 0.9),
                    control1: CGPoint(x: size.width * 0.35, y: -size.height * 0.2),
                    control2: CGPoint(x: size.width * 0.65, y: -size.height * 0.2)
                )
                context.stroke(curve, with: .color(DesignColor.brandPrimary), lineWidth: 2)
            }
            .padding(DesignSpace.s3)

        case .wolfram:
            VStack(alignment: .leading, spacing: DesignSpace.s2) {
                HStack {
                    Text("f(x)").font(.system(size: 12, design: .monospaced)).foregroundStyle(DesignColor.textTertiary)
                    Rectangle().fill(DesignColor.surfaceSunken).frame(height: 16).frame(width: 140)
                }
                Rectangle().fill(DesignColor.borderDefault).frame(height: 1)
                Rectangle().fill(DesignColor.surfaceSunken).frame(height: 14).frame(width: 100)
            }

        case .document:
            HStack(spacing: DesignSpace.s2) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<5, id: \.self) { i in
                        Rectangle().fill(DesignColor.borderSubtle).frame(height: 3).frame(width: CGFloat(50 - i * 4))
                    }
                }
                .padding(8)
                .frame(width: 60, height: 76)
                .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(DesignColor.borderDefault))
            }
        }
    }
}
