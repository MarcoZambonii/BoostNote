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
    @Binding var inkColors: [PenTool: Color]
    @Binding var inkWidths: [PenTool: CGFloat]
    @Binding var eraserType: PKEraserTool.EraserType
    @Binding var eraserWidth: CGFloat
    @Binding var magicAction: MagicAction?
    var isMagicProcessing: Bool = false
    @Binding var dock: ToolbarDock
    // Non-nil solo mentre si trascina: il bordo su cui la barra atterrerebbe
    // se rilasciata ora, per mostrare i 4 placeholder nel genitore.
    @Binding var dragPreviewDock: ToolbarDock?
    var containerSize: CGSize
    var onInsertImage: () -> Void
    var onInsertPDF: () -> Void
    var onInsertPDFFromWebeep: () -> Void

    private let colors: [Color] = [.black, .red, .blue, .green, .orange, .purple]

    @State private var showingEraserOptions = false
    @State private var showingOptionsFor: PenTool?
    @State private var showingInkPicker = false
    @State private var showingLassoInfo = false
    @State private var showingMagicPicker = false
    @State private var dragOffset: CGSize = .zero
    @GestureState private var isDragging = false

    private var axis: Axis { dock.axis }

    var body: some View {
        let layout: AnyLayout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 14))
            : AnyLayout(VStackLayout(spacing: 14))

        ScrollView(axis == .horizontal ? .horizontal : .vertical, showsIndicators: false) {
            layout {
                ForEach(visibleInks) { tool in
                    inkToolButton(tool)
                }

                moreInksButton

                eraserButton

                lassoButton

                ForEach([PenTool.text, .pointer]) { tool in
                    Button {
                        selectedTool = tool
                    } label: {
                        toolIcon(tool.systemImage, isSelected: selectedTool == tool)
                    }
                    .accessibilityLabel(tool.label)
                }

                divider

                magicMenu

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
                        Label("PDF dai file", systemImage: "doc.richtext")
                    }
                    Button {
                        onInsertPDFFromWebeep()
                    } label: {
                        Label("PDF da WeBeep", systemImage: "graduationcap")
                    }
                } label: {
                    toolIcon("photo.badge.plus", isSelected: false)
                }
                .accessibilityLabel("Inserisci immagine o PDF")

                divider

                dragHandle
            }
            .padding(axis == .horizontal ? 6 : 8)
        }
        // Barra più compatta: copre meno foglio, che su una nota piena di
        // scrittura è il difetto che si nota di più.
        .frame(maxWidth: axis == .horizontal ? 560 : 46)
        .frame(maxHeight: axis == .vertical ? 460 : 46)
        // ultraThin invece di regular: si legge cosa c'è sotto, così la
        // barra sembra appoggiata sul foglio invece di bucarlo.
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DesignRadius.pill, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.pill, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.pill, style: .continuous)
                .stroke(DesignColor.borderDefault.opacity(0.5), lineWidth: 1)
        )
        // Ombra più morbida e diffusa: prima era un alone netto che
        // faceva sembrare la barra incollata sopra invece che sospesa.
        .shadow(color: .black.opacity(isDragging ? 0.18 : 0.10), radius: isDragging ? 24 : 18, y: 6)
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
        Button {
            showingMagicPicker = true
        } label: {
            HStack(spacing: 6) {
                if isMagicProcessing {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(magicAction != nil ? magicAction!.color : .white)
                } else {
                    Image(systemName: magicAction?.systemImage ?? "wand.and.stars")
                        .font(.system(size: 15, weight: .semibold))
                }
                if axis == .horizontal {
                    Text(isMagicProcessing ? "Elaborazione…" : (magicAction?.label ?? "Magica"))
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
        .buttonStyle(.plain)
        .disabled(isMagicProcessing)
        .accessibilityLabel("Penna magica")
        // Stessa lista stile "catalogo" del picker Strumenti
        // (ToolsPickerSheet), senza il pannello di dettaglio a destra —
        // qui basta scegliere l'azione, non serve una spiegazione.
        .popover(isPresented: $showingMagicPicker) {
            MagicActionPickerView(current: magicAction) { action in
                magicAction = action
                showingMagicPicker = false
            }
        }
    }

    // MARK: - Inchiostri

    // Gli inchiostri di uso quotidiano stanno sempre in barra; gli altri
    // vivono nel menu "altri inchiostri". Sette icone in fila renderebbero
    // la pillola una barra di scorrimento, e il difetto che si nota di più
    // su una nota piena è proprio quanto foglio copre la barra.
    private let primaryInks: [PenTool] = [.pen, .marker]

    // L'inchiostro selezionato è SEMPRE visibile, anche se scelto dal
    // menu: altrimenti si scriverebbe con l'acquerello senza vedere da
    // nessuna parte quale strumento è attivo né come cambiarne il colore.
    private var visibleInks: [PenTool] {
        guard selectedTool.isInk, !primaryInks.contains(selectedTool) else { return primaryInks }
        return primaryInks + [selectedTool]
    }

    private var secondaryInks: [PenTool] {
        PenTool.inkTools.filter { !primaryInks.contains($0) }
    }

    // Circa 30 tacche su tutto l'intervallo, arrotondate a un valore
    // "tondo" perché lo slider si fermi su numeri leggibili.
    private func sliderStep(for range: ClosedRange<CGFloat>) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        if span <= 5 { return 0.1 }
        if span <= 20 { return 0.5 }
        return 1
    }

    private func snappedRange(_ range: ClosedRange<CGFloat>) -> ClosedRange<CGFloat> {
        let lower = range.lowerBound.rounded(.up)
        let upper = range.upperBound.rounded(.down)
        guard lower < upper else { return range }
        return lower...upper
    }

    private func colorBinding(for tool: PenTool) -> Binding<Color> {
        Binding(
            get: { inkColors[tool] ?? tool.defaultColor },
            set: { inkColors[tool] = $0 }
        )
    }

    private func widthBinding(for tool: PenTool) -> Binding<CGFloat> {
        Binding(
            get: { inkWidths[tool] ?? tool.defaultWidth },
            set: { inkWidths[tool] = $0 }
        )
    }

    // Come la gomma: un tocco seleziona lo strumento (con l'ultimo
    // colore/spessore usati); un secondo tocco, a strumento già
    // selezionato, apre colore + spessore punta.
    @ViewBuilder
    private func inkToolButton(_ tool: PenTool) -> some View {
        let color = colorBinding(for: tool)
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
            inkOptions(for: tool)
                .padding(DesignSpace.s4)
                .frame(width: 260)
                .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    private var moreInksButton: some View {
        // Gli inchiostri sono tornati a essere solo i tre principali:
        // senza questo controllo resterebbe in barra un pulsante che apre
        // un elenco vuoto.
        if secondaryInks.isEmpty {
            EmptyView()
        } else {
            Button {
                showingInkPicker = true
            } label: {
            toolIcon("paintbrush.pointed.fill", isSelected: secondaryInks.contains(selectedTool))
        }
        .accessibilityLabel("Altri inchiostri")
        .popover(isPresented: $showingInkPicker) {
            VStack(alignment: .leading, spacing: DesignSpace.s2) {
                Text("Altri inchiostri")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignColor.textTertiary)

                ForEach(secondaryInks) { tool in
                    Button {
                        selectedTool = tool
                        showingInkPicker = false
                    } label: {
                        HStack(spacing: DesignSpace.s3) {
                            Image(systemName: tool.systemImage)
                                .font(.system(size: 16))
                                .frame(width: 24)
                                .foregroundStyle(selectedTool == tool ? DesignColor.brandPrimary : DesignColor.textSecondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tool.label)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(DesignColor.textPrimary)
                                Text(tool.hint)
                                    .font(.system(size: 11))
                                    .foregroundStyle(DesignColor.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Circle()
                                .fill(inkColors[tool] ?? tool.defaultColor)
                                .frame(width: 14, height: 14)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
                .padding(DesignSpace.s4)
                .frame(width: 290)
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    @ViewBuilder
    private func inkOptions(for tool: PenTool) -> some View {
        let color = colorBinding(for: tool)
        let width = widthBinding(for: tool)
        let range = tool.widthRange
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            Text(tool.hint)
                .font(.system(size: 11))
                .foregroundStyle(DesignColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            inkOptionsBody(color: color, width: width, widthRange: range)
        }
    }

    private func inkOptionsBody(color: Binding<Color>, width: Binding<CGFloat>, widthRange: ClosedRange<CGFloat>) -> some View {
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
                    // In punti: i millimetri qui confondevano (deciso
                    // dall'utente); restano sul passo dei quadretti.
                    Text(Double(width.wrappedValue).formatted(.number.precision(.fractionLength(0...1))))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(DesignColor.textTertiary)
                }
                // Passo proporzionale all'intervallo: con `step: 1` fisso
                // il tratto fisso (0,5-4) aveva quattro sole posizioni
                // utili, mentre l'acquerello (10-80) ne aveva settanta.
                //
                // Estremi arrotondati al numero tondo: l'intervallo nativo
                // di PencilKit parte da valori spuri (la penna da 0,9) e a
                // passi interi il decimale restava inchiodato — "2,9",
                // "3,9" — sembrando un secondo numero fisso senza senso.
                Slider(value: width, in: snappedRange(widthRange), step: sliderStep(for: widthRange))
                    .tint(DesignColor.brandPrimary)
                // Anteprima del tratto: scegliere uno spessore leggendo un
                // numero significa provare e disfare finché non è giusto.
                Capsule()
                    .fill(color.wrappedValue)
                    .frame(height: max(1, min(width.wrappedValue, 26)))
                    .frame(maxWidth: .infinity)
                    .animation(.easeOut(duration: 0.12), value: width.wrappedValue)
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
            toolIcon("eraser.fill", isSelected: selectedTool == .eraser)
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

            // Una sola gomma, a oggetti. La "Precisa" (parziale) è stata
            // riprovata il 2026-08-14 con la pagina attiva sul motore
            // sincrono e non funziona ancora: rispenta su decisione
            // dell'utente, senza indagare oltre per ora. Il codice di
            // divisione (InkEraser.split) resta, dormiente.
            Text("Toglie il tratto intero che tocchi.")
                .font(.system(size: 11))
                .foregroundStyle(DesignColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

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
                // Anteprima in scala reale della punta.
                HStack {
                    Spacer()
                    Circle()
                        .fill(DesignColor.textTertiary.opacity(0.18))
                        .overlay(Circle().stroke(DesignColor.borderDefault, lineWidth: 1))
                        .frame(width: eraserWidth, height: eraserWidth)
                    Spacer()
                }
                .frame(height: 84)
            }
            // Le cancellazioni in blocco ("togli evidenziature",
            // "cancella tutta la pagina") sono state tolte su richiesta
            // dell'utente (2026-08-16): il popover della gomma torna a
            // fare una cosa sola, la dimensione. Il codice sotto
            // (clearHighlighter/clearPage in DrawingCanvasView) resta —
            // se un giorno serviranno, il posto giusto sarà un menu della
            // pagina, non lo strumento.
        }
    }

    // Il lazo, come la gomma: un tocco lo seleziona, un secondo spiega
    // cosa ci si può fare. Le operazioni sulla selezione (duplica,
    // copia, taglia, elimina) vivono nella barretta che compare sopra il
    // recinto — il lasso è NOSTRO (LiveInkCaptureOverlay), PencilKit non
    // partecipa più: le istruzioni qui sotto descrivono quello vero.
    @ViewBuilder
    private var lassoButton: some View {
        Button {
            if selectedTool == .lasso {
                showingLassoInfo = true
            } else {
                selectedTool = .lasso
            }
        } label: {
            toolIcon(PenTool.lasso.systemImage, isSelected: selectedTool == .lasso)
        }
        .accessibilityLabel(PenTool.lasso.label)
        .popover(isPresented: $showingLassoInfo) {
            VStack(alignment: .leading, spacing: DesignSpace.s3) {
                Text("Selezione")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignColor.textTertiary)
                lassoStep("1", "Cerchia quello che ti interessa.")
                lassoStep("2", "Trascina la selezione per spostarla.")
                lassoStep("3", "Usa la barretta sopra la selezione per duplicare, copiare, tagliare o eliminare.")
                Divider()
                Text("Con qualcosa negli appunti, un tocco su un punto vuoto lo incolla lì. Funziona sull'inchiostro, non sulle caselle di testo: quelle si spostano trascinandole direttamente.")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignSpace.s4)
            .frame(width: 280)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func lassoStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DesignSpace.s2) {
            Text(number)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(DesignColor.brandPrimary)
                .frame(width: 16, height: 16)
                .background(DesignColor.brandPrimarySubtle, in: Circle())
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(DesignColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

// Stessa lista "a catalogo" di ToolsPickerSheet (ricerca + riga
// icona/nome, stato selezionato evidenziato) ma senza il pannello di
// dettaglio a destra: qui si sceglie e via, non serve un'anteprima.
private struct MagicActionPickerView: View {
    var current: MagicAction?
    var onSelect: (MagicAction?) -> Void

    @State private var query = ""

    private var filteredActions: [MagicAction] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return MagicAction.allCases }
        return MagicAction.allCases.filter { $0.label.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSpace.s2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignColor.textTertiary)
                TextField("Cerca azioni", text: $query)
                    .font(.system(size: 14))
                    .textFieldStyle(.plain)
            }
            .padding(DesignSpace.s3)
            .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
            .padding(DesignSpace.s3)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filteredActions) { action in
                        Button {
                            onSelect(action)
                        } label: {
                            HStack(spacing: DesignSpace.s3) {
                                Image(systemName: action.systemImage)
                                    .font(.system(size: 15))
                                    .foregroundStyle(current == action ? action.color : DesignColor.textSecondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(action.label)
                                        .font(.system(size: 14, weight: current == action ? .semibold : .medium))
                                        .foregroundStyle(current == action ? action.color : DesignColor.textPrimary)
                                    Text(action.subtitle)
                                        .font(.system(size: 11))
                                        .foregroundStyle(DesignColor.textTertiary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, DesignSpace.s3)
                            .padding(.vertical, DesignSpace.s2 + 2)
                            .background(
                                current == action ? action.backgroundColor : Color.clear,
                                in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if current != nil {
                        Divider().padding(.vertical, DesignSpace.s2)
                        Button {
                            onSelect(nil)
                        } label: {
                            HStack(spacing: DesignSpace.s3) {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 15))
                                    .foregroundStyle(DesignColor.danger)
                                    .frame(width: 22)
                                Text("Disattiva")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(DesignColor.danger)
                                Spacer()
                            }
                            .padding(.horizontal, DesignSpace.s3)
                            .padding(.vertical, DesignSpace.s2 + 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DesignSpace.s2)
                .padding(.bottom, DesignSpace.s3)
            }
        }
        .frame(width: 280, height: 380)
        .background(DesignColor.surfaceSunken)
    }
}
