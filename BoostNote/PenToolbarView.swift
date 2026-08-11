import SwiftUI
import PencilKit

enum ToolbarDock: String, CaseIterable {
    case top, bottom, leading, trailing

    var alignment: Alignment {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    var axis: Axis {
        self == .leading || self == .trailing ? .vertical : .horizontal
    }

    var label: String {
        switch self {
        case .top: "Sopra"
        case .bottom: "Sotto"
        case .leading: "Sinistra"
        case .trailing: "Destra"
        }
    }

    var systemImage: String {
        switch self {
        case .top: "arrow.up.to.line"
        case .bottom: "arrow.down.to.line"
        case .leading: "arrow.left.to.line"
        case .trailing: "arrow.right.to.line"
        }
    }

    // Punto di ancoraggio della barra sul bordo scelto, dato lo spazio disponibile.
    func anchor(in size: CGSize) -> CGPoint {
        switch self {
        case .top: CGPoint(x: size.width / 2, y: 0)
        case .bottom: CGPoint(x: size.width / 2, y: size.height)
        case .leading: CGPoint(x: 0, y: size.height / 2)
        case .trailing: CGPoint(x: size.width, y: size.height / 2)
        }
    }

    // Bordo più vicino a un punto dato: la barra vive solo nei 4 punti medi
    // dei lati, mai in un punto libero della pagina.
    static func nearest(to point: CGPoint, in size: CGSize) -> ToolbarDock {
        let distances: [(ToolbarDock, CGFloat)] = [
            (.top, point.y),
            (.bottom, size.height - point.y),
            (.leading, point.x),
            (.trailing, size.width - point.x)
        ]
        return distances.min { $0.1 < $1.1 }?.0 ?? .top
    }
}

// Barra strumenti "a isola" flottante, in stile Claude Design
// (PenToolbar.jsx): pillola con ombra, agganciabile ai 4 lati del foglio.
// Si trascina dalla maniglia a destra e si aggancia magneticamente al
// bordo più vicino al rilascio, come i pannelli di sistema su iPad.
struct PenToolbarView: View {
    @Binding var selectedTool: PenTool
    @Binding var penColor: Color
    @Binding var penWidth: CGFloat
    @Binding var markerColor: Color
    @Binding var markerWidth: CGFloat
    @Binding var pencilColor: Color
    @Binding var pencilWidth: CGFloat
    @Binding var eraserType: PKEraserTool.EraserType
    @Binding var eraserWidth: CGFloat
    @Binding var magicAction: MagicAction?
    @Binding var dock: ToolbarDock
    // Non-nil solo mentre si trascina: il bordo su cui la barra atterrerebbe
    // se rilasciata ora, per mostrare i 4 placeholder nel genitore.
    @Binding var dragPreviewDock: ToolbarDock?
    var containerSize: CGSize
    var onInsertImage: () -> Void
    var onInsertPDF: () -> Void

    private let colors: [Color] = [.black, .red, .blue, .green, .orange, .purple]

    @State private var showingEraserOptions = false
    @State private var showingOptionsFor: PenTool?
    @State private var dragOffset: CGSize = .zero
    @GestureState private var isDragging = false

    private var axis: Axis { dock.axis }

    var body: some View {
        let layout: AnyLayout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 14))
            : AnyLayout(VStackLayout(spacing: 14))

        ScrollView(axis == .horizontal ? .horizontal : .vertical, showsIndicators: false) {
            layout {
                ForEach(PenTool.allCases) { tool in
                    switch tool {
                    case .eraser:
                        eraserButton
                    case .pen:
                        inkToolButton(.pen, color: $penColor, width: $penWidth, widthRange: 1...12)
                    case .marker:
                        inkToolButton(.marker, color: $markerColor, width: $markerWidth, widthRange: 6...30)
                    case .pencil:
                        inkToolButton(.pencil, color: $pencilColor, width: $pencilWidth, widthRange: 1...10)
                    default:
                        Button {
                            selectedTool = tool
                        } label: {
                            toolIcon(tool.systemImage, isSelected: selectedTool == tool)
                        }
                        .accessibilityLabel(tool.label)
                    }
                }

                divider

                magicMenu

                if magicAction != nil {
                    Text("Cerchia un'espressione")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(magicAction!.color)
                        .fixedSize()
                }

                divider

                Menu {
                    Button {
                        onInsertImage()
                    } label: {
                        Label("Immagine", systemImage: "photo")
                    }
                    Button {
                        onInsertPDF()
                    } label: {
                        Label("PDF", systemImage: "doc.richtext")
                    }
                } label: {
                    toolIcon("photo.badge.plus", isSelected: false)
                }
                .accessibilityLabel("Inserisci immagine o PDF")

                divider

                dragHandle
            }
            .padding(axis == .horizontal ? 8 : 10)
        }
        .frame(maxWidth: axis == .horizontal ? 660 : 52)
        .frame(maxHeight: axis == .vertical ? 520 : 52)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignRadius.pill, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.pill, style: .continuous)
                .stroke(DesignColor.borderDefault, lineWidth: 1)
        )
        .shadow(color: .black.opacity(isDragging ? 0.22 : 0.14), radius: isDragging ? 20 : 14, y: 4)
        .scaleEffect(isDragging ? 1.03 : 1)
        .offset(dragOffset)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: dragOffset)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: dock)
    }

    @ViewBuilder
    private var divider: some View {
        Divider().frame(height: axis == .horizontal ? 22 : nil)
            .frame(width: axis == .vertical ? 22 : nil)
    }

    // Maniglia di trascinamento: tenerla premuta e trascinare sposta la
    // barra, che si aggancia magneticamente al bordo più vicino al rilascio.
    @ViewBuilder
    private var dragHandle: some View {
        Image(systemName: "circle.grid.3x3.fill")
            .font(.system(size: 15))
            .foregroundStyle(DesignColor.textTertiary)
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .named("canvasArea"))
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { value in
                        dragOffset = value.translation
                        guard containerSize.width > 0, containerSize.height > 0 else { return }
                        let anchor = dock.anchor(in: containerSize)
                        let point = CGPoint(x: anchor.x + value.translation.width, y: anchor.y + value.translation.height)
                        dragPreviewDock = ToolbarDock.nearest(to: point, in: containerSize)
                    }
                    .onEnded { value in
                        defer { dragOffset = .zero; dragPreviewDock = nil }
                        guard containerSize.width > 0, containerSize.height > 0 else { return }
                        let anchor = dock.anchor(in: containerSize)
                        let released = CGPoint(x: anchor.x + value.translation.width, y: anchor.y + value.translation.height)
                        dock = ToolbarDock.nearest(to: released, in: containerSize)
                    }
            )
            .accessibilityLabel("Sposta la barra strumenti")
    }

    @ViewBuilder
    private var magicMenu: some View {
        Menu {
            ForEach(MagicAction.allCases) { action in
                Button {
                    magicAction = action
                } label: {
                    Label(action.label, systemImage: action.systemImage)
                }
            }
            if magicAction != nil {
                Divider()
                Button(role: .destructive) {
                    magicAction = nil
                } label: {
                    Label("Disattiva", systemImage: "xmark.circle")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: magicAction?.systemImage ?? "wand.and.stars")
                    .font(.system(size: 15, weight: .semibold))
                if axis == .horizontal {
                    Text(magicAction?.label ?? "Magica")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .padding(.horizontal, axis == .horizontal ? 14 : 0)
            .frame(minWidth: axis == .vertical ? 34 : nil)
            .frame(height: 34)
            .foregroundStyle(magicAction != nil ? magicAction!.color : .white)
            .background(
                magicAction != nil ? AnyShapeStyle(magicAction!.backgroundColor) : AnyShapeStyle(DesignColor.brandPrimary),
                in: Capsule()
            )
        }
        .accessibilityLabel("Penna magica")
    }

    // Come la gomma: un tocco seleziona lo strumento (con l'ultimo
    // colore/spessore usati); un secondo tocco, a strumento già
    // selezionato, apre colore + spessore punta.
    @ViewBuilder
    private func inkToolButton(_ tool: PenTool, color: Binding<Color>, width: Binding<CGFloat>, widthRange: ClosedRange<CGFloat>) -> some View {
        Button {
            if selectedTool == tool {
                showingOptionsFor = tool
            } else {
                selectedTool = tool
            }
        } label: {
            toolIcon(tool.systemImage, isSelected: selectedTool == tool, tint: selectedTool == tool ? color.wrappedValue : nil)
        }
        .accessibilityLabel(tool.label)
        .popover(isPresented: Binding(
            get: { showingOptionsFor == tool },
            set: { if !$0 { showingOptionsFor = nil } }
        )) {
            inkOptions(color: color, width: width, widthRange: widthRange)
                .padding(DesignSpace.s4)
                .frame(width: 240)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func inkOptions(color: Binding<Color>, width: Binding<CGFloat>, widthRange: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: DesignSpace.s4) {
            Text("Colore")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignColor.textTertiary)

            HStack(spacing: DesignSpace.s2) {
                ForEach(colors, id: \.self) { option in
                    Button {
                        color.wrappedValue = option
                    } label: {
                        Circle()
                            .fill(option)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle()
                                    .stroke(DesignColor.textPrimary, lineWidth: color.wrappedValue == option ? 2 : 0)
                                    .padding(-2)
                            )
                    }
                }
                ColorPicker("", selection: color)
                    .labelsHidden()
                    .frame(width: 24, height: 24)
            }

            VStack(alignment: .leading, spacing: DesignSpace.s2) {
                HStack {
                    Text("Spessore punta")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignColor.textSecondary)
                    Spacer()
                    Text("\(Int(width.wrappedValue))")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(DesignColor.textTertiary)
                }
                Slider(value: width, in: widthRange, step: 1)
                    .tint(DesignColor.brandPrimary)
            }
        }
    }

    // Un tocco seleziona la gomma (con l'ultimo tipo/dimensione usati); un
    // secondo tocco, a gomma già selezionata, apre tipo + dimensione.
    @ViewBuilder
    private var eraserButton: some View {
        Button {
            if selectedTool == .eraser {
                showingEraserOptions = true
            } else {
                selectedTool = .eraser
            }
        } label: {
            toolIcon(eraserType == .vector ? "eraser.fill" : "eraser", isSelected: selectedTool == .eraser)
        }
        .accessibilityLabel("Gomma")
        .popover(isPresented: $showingEraserOptions) {
            eraserOptions
                .padding(DesignSpace.s4)
                .frame(width: 240)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var eraserOptions: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s4) {
            Text("Gomma")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignColor.textTertiary)

            HStack(spacing: DesignSpace.s3) {
                eraserTypeButton(.bitmap, label: "Semplice", systemImage: "eraser")
                eraserTypeButton(.vector, label: "A oggetti", systemImage: "eraser.fill")
            }

            VStack(alignment: .leading, spacing: DesignSpace.s2) {
                HStack {
                    Text("Dimensione")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignColor.textSecondary)
                    Spacer()
                    Text("\(Int(eraserWidth))")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(DesignColor.textTertiary)
                }
                Slider(value: $eraserWidth, in: 10...80, step: 2)
                    .tint(DesignColor.brandPrimary)
            }
        }
    }

    @ViewBuilder
    private func eraserTypeButton(_ type: PKEraserTool.EraserType, label: String, systemImage: String) -> some View {
        Button {
            eraserType = type
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(eraserType == type ? DesignColor.brandPrimary : DesignColor.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSpace.s2)
            .background(
                eraserType == type ? DesignColor.brandPrimarySubtle : DesignColor.surfaceSunken,
                in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func toolIcon(_ systemImage: String, isSelected: Bool, tint: Color? = nil) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(isSelected ? (tint ?? DesignColor.brandPrimary) : DesignColor.textPrimary)
            .frame(width: 34, height: 34)
            .background(
                isSelected ? (tint ?? DesignColor.brandPrimary).opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
            )
    }
}
