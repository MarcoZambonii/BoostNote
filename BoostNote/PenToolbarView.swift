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

// Una penna salvata dall'utente: strumento, colore, spessore e
// pressione tenuti insieme. Riprenderla costa un tocco invece di
// rifare ogni volta la stessa configurazione.
struct PinnedPen: Codable, Identifiable, Equatable {
    var id = UUID()
    var toolRaw: String
    var colorHex: String
    var width: Double
    var pressure: Bool

    var tool: PenTool { PenTool(rawValue: toolRaw) ?? .pen }
    var color: Color { Color(hexString: colorHex) ?? .black }

    // Due penne sono "la stessa" quando coincide la configurazione, non
    // l'id: serve a capire se quella in mano è già appuntata in barra.
    func matchesConfiguration(of other: PinnedPen) -> Bool {
        toolRaw == other.toolRaw
            && colorHex.caseInsensitiveCompare(other.colorHex) == .orderedSame
            && abs(width - other.width) < 0.05
            && pressure == other.pressure
    }
}

// Barra strumenti "a isola" flottante, in stile Claude Design
// (PenToolbar.jsx): superficie bianca con ombra, agganciabile ai 4 lati
// del foglio. Si trascina dalla maniglia a destra e si aggancia
// magneticamente al bordo più vicino al rilascio.
struct PenToolbarView: View {
    @Binding var selectedTool: PenTool
    @Binding var inkColors: [PenTool: Color]
    @Binding var inkWidths: [PenTool: CGFloat]
    // Penna a pressione (tratto che varia con la forza) oppure a
    // spessore costante: è una proprietà della penna quanto il colore.
    @Binding var pressureEnabled: [PenTool: Bool]
    // Forma del recinto: a mano libera o rettangolo.
    @Binding var lassoShape: LassoShape
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

    // Le penne dell'utente, salvate come JSON: sopravvivono alla nota e
    // all'app. Sono una scorciatoia, non uno stato del disegno — per
    // questo vivono qui e non fra le preferenze passate dall'editor.
    @AppStorage("tool.pinnedPens") private var storedPinnedPens = ""

    private var axis: Axis { dock.axis }

    // Massimo sei: oltre, la barra non ci sta più su un iPad in verticale
    // e le penne si mangerebbero gli strumenti.
    private static let maxPinnedPens = 6

    var pinnedPens: [PinnedPen] {
        get {
            storedPinnedPens.data(using: .utf8)
                .flatMap { try? JSONDecoder().decode([PinnedPen].self, from: $0) } ?? []
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(Array(newValue.prefix(Self.maxPinnedPens))),
                  let string = String(data: data, encoding: .utf8) else { return }
            storedPinnedPens = string
        }
    }

    // La penna attualmente in mano, com'è configurata adesso.
    private func currentPen(for tool: PenTool) -> PinnedPen {
        PinnedPen(
            toolRaw: tool.rawValue,
            colorHex: (inkColors[tool] ?? tool.defaultColor).hexString ?? "#000000",
            width: Double(inkWidths[tool] ?? tool.defaultWidth),
            pressure: pressureEnabled[tool] ?? true
        )
    }

    private func isPinned(_ pen: PinnedPen) -> Bool {
        pinnedPens.contains { $0.matchesConfiguration(of: pen) }
    }

    private func togglePin(for tool: PenTool) {
        let pen = currentPen(for: tool)
        if let index = pinnedPens.firstIndex(where: { $0.matchesConfiguration(of: pen) }) {
            var pens = pinnedPens
            pens.remove(at: index)
            pinnedPens = pens
        } else {
            pinnedPens = pinnedPens + [pen]
        }
    }

    // Riprendere una penna significa rimettere in mano ESATTAMENTE quella
    // configurazione: strumento, colore, spessore e pressione insieme.
    private func apply(_ pen: PinnedPen) {
        let tool = pen.tool
        inkColors[tool] = pen.color
        inkWidths[tool] = CGFloat(pen.width)
        pressureEnabled[tool] = pen.pressure
        selectedTool = tool
    }

    private func isActive(_ pen: PinnedPen) -> Bool {
        selectedTool == pen.tool && currentPen(for: pen.tool).matchesConfiguration(of: pen)
    }

    // Tasto di una penna salvata: il glifo dello strumento con sotto la
    // riga del suo colore, come nel mock.
    @ViewBuilder
    private func pinnedPenButton(_ pen: PinnedPen) -> some View {
        let active = isActive(pen)
        Button {
            apply(pen)
        } label: {
            Image(systemName: pen.tool.systemImage)
                .font(.system(size: DesignIcon.md))
                .foregroundStyle(active ? pen.color : DesignColor.textPrimary)
                .frame(width: 34, height: 34)
                .background(
                    active ? pen.color.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                )
                .overlay(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(pen.color)
                        .frame(width: 12, height: 2.5)
                        .opacity(active ? 1 : 0.45)
                        .padding(.bottom, DesignSpace.s1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(pen.tool.label) salvata")
        .contextMenu {
            Button(role: .destructive) {
                pinnedPens = pinnedPens.filter { $0.id != pen.id }
            } label: {
                Label("Togli dalla barra", systemImage: "pin.slash")
            }
        }
    }

    var body: some View {
        let layout: AnyLayout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 14))
            : AnyLayout(VStackLayout(spacing: 14))

        ScrollView(axis == .horizontal ? .horizontal : .vertical, showsIndicators: false) {
            layout {
                ForEach(visibleInks) { tool in
                    inkToolButton(tool)
                }

                ForEach(pinnedPens) { pen in
                    pinnedPenButton(pen)
                }

                moreInksButton

                eraserButton

                lassoButton

                if selectedTool == .lasso {
                    lassoShapeToggle
                }

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
            .padding(3)
        }
        // Barra più compatta: copre meno foglio, che su una nota piena di
        // scrittura è il difetto che si nota di più.
        // Stessa altezza della barra fissa in alto a destra e del tasto
        // indietro: 40. Erano 46 e la differenza si notava.
        .frame(maxWidth: axis == .horizontal ? 560 : 40)
        .frame(maxHeight: axis == .vertical ? 460 : 40)
        // Bianca e squadrata come ogni altra superficie sospesa (barra
        // fissa, pannelli): la pillola traslucida era l'unico pezzo
        // d'app con una forma e un materiale tutti suoi.
        .background(DesignColor.surfaceOverlay, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous)
                .strokeBorder(DesignColor.borderDefault, lineWidth: 1)
        )
        .shadow(color: .black.opacity(isDragging ? 0.20 : 0.12), radius: isDragging ? 26 : 20, y: 7)
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
        Image(systemName: "line.3.horizontal")
            .font(.system(size: DesignIcon.md))
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
                    Image(systemName: magicAction?.systemImage ?? "sparkles")
                        .font(.system(size: DesignIcon.md))
                }
                if axis == .horizontal {
                    Text(isMagicProcessing ? "Genero…" : (magicAction?.label ?? "Magica"))
                        .font(DesignFont.action)
                }
            }
            .padding(.horizontal, axis == .horizontal ? 14 : 0)
            .frame(minWidth: axis == .vertical ? 34 : nil)
            .frame(height: 34)
            .foregroundStyle(magicAction != nil ? magicAction!.color : .white)
            .background(
                magicAction != nil ? AnyShapeStyle(magicAction!.backgroundColor) : AnyShapeStyle(DesignColor.brandPrimary),
                in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
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
            toolIcon(tool.systemImage, isSelected: selectedTool == tool, tint: selectedTool == tool ? color.wrappedValue : nil, inkColor: color.wrappedValue)
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
                    .font(DesignFont.cardTitle)
                    .foregroundStyle(DesignColor.textTertiary)

                ForEach(secondaryInks) { tool in
                    Button {
                        selectedTool = tool
                        showingInkPicker = false
                    } label: {
                        HStack(spacing: DesignSpace.s3) {
                            Image(systemName: tool.systemImage)
                                .font(.system(size: DesignIcon.md))
                                .frame(width: 24)
                                .foregroundStyle(selectedTool == tool ? DesignColor.brandPrimary : DesignColor.textSecondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tool.label)
                                    .font(DesignFont.body)
                                    .foregroundStyle(DesignColor.textPrimary)
                                Text(tool.hint)
                                    .font(DesignFont.caption)
                                    .foregroundStyle(DesignColor.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Circle()
                                .fill(inkColors[tool] ?? tool.defaultColor)
                                .frame(width: 14, height: 14)
                        }
                        .padding(.vertical, DesignSpace.s1)
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

    // Interruttore della pressione: acceso, il tratto ingrossa dove
    // premi; spento ha spessore identico ovunque. Solo la penna può
    // farlo davvero — l'inchiostro a spessore costante di PencilKit
    // (monoline) non supera i 4 punti, e un evidenziatore da 4 punti
    // non evidenzia niente.
    @ViewBuilder
    private func pressureToggle(for tool: PenTool) -> some View {
        if tool.supportsConstantWidth {
            let binding = Binding(
                get: { pressureEnabled[tool] ?? true },
                set: { isOn in
                    pressureEnabled[tool] = isOn
                    // Spegnendo la pressione l'intervallo si stringe: uno
                    // spessore da 12 resterebbe scritto nello slider ma
                    // il tratto uscirebbe da 4.
                    let range = tool.widthRange(pressure: isOn)
                    let current = inkWidths[tool] ?? tool.defaultWidth
                    inkWidths[tool] = min(max(current, range.lowerBound), range.upperBound)
                }
            )
            VStack(alignment: .leading, spacing: DesignSpace.s1) {
                Toggle(isOn: binding) {
                    Text("Sensibile alla pressione")
                        .font(DesignFont.label)
                        .foregroundStyle(DesignColor.textSecondary)
                }
                .tint(DesignColor.brandPrimary)

                Text(binding.wrappedValue
                     ? "Il tratto ingrossa dove premi."
                     : "Tratto identico ovunque, fino a 4 punti.")
                    .font(DesignFont.caption)
                    .foregroundStyle(DesignColor.textTertiary)
            }
        }
    }

    // Appuntare la penna in barra: la configurazione attuale diventa un
    // tasto, e un secondo tocco sullo stesso comando la toglie.
    @ViewBuilder
    private func pinButton(for tool: PenTool) -> some View {
        let pen = currentPen(for: tool)
        let pinned = isPinned(pen)
        BoostButton(
            pinned ? "Togli dalla barra" : "Appunta in barra",
            icon: pinned ? "pin.slash" : "pin",
            tone: pinned ? .ghost : .secondary,
            size: .compact,
            fullWidth: true
        ) {
            togglePin(for: tool)
        }
        .disabled(!pinned && pinnedPens.count >= Self.maxPinnedPens)
    }

    @ViewBuilder
    private func inkOptions(for tool: PenTool) -> some View {
        let color = colorBinding(for: tool)
        let width = widthBinding(for: tool)
        // A pressione spenta l'intervallo si stringe (0,5-4): lo slider
        // deve mostrare quello vero, non promettere spessori che
        // PencilKit taglierebbe in silenzio.
        let range = tool.widthRange(pressure: pressureEnabled[tool] ?? true)
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            Text(tool.hint)
                .font(DesignFont.caption)
                .foregroundStyle(DesignColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            inkOptionsBody(color: color, width: width, widthRange: range)
            pressureToggle(for: tool)
            Divider()
            pinButton(for: tool)
        }
    }

    private func inkOptionsBody(color: Binding<Color>, width: Binding<CGFloat>, widthRange: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: DesignSpace.s4) {
            Text("Colore")
                .font(DesignFont.cardTitle)
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
                        .font(DesignFont.label)
                        .foregroundStyle(DesignColor.textSecondary)
                    Spacer()
                    // In punti: i millimetri qui confondevano (deciso
                    // dall'utente); restano sul passo dei quadretti.
                    Text(Double(width.wrappedValue).formatted(.number.precision(.fractionLength(0...1))))
                        .font(DesignFont.mono)
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
                .font(DesignFont.cardTitle)
                .foregroundStyle(DesignColor.textTertiary)

            // Una sola gomma, a oggetti. La "Precisa" (parziale) è stata
            // riprovata il 2026-08-14 con la pagina attiva sul motore
            // sincrono e non funziona ancora: rispenta su decisione
            // dell'utente, senza indagare oltre per ora. Il codice di
            // divisione (InkEraser.split) resta, dormiente.
            Text("Toglie il tratto intero che tocchi.")
                .font(DesignFont.caption)
                .foregroundStyle(DesignColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: DesignSpace.s2) {
                HStack {
                    Text("Dimensione")
                        .font(DesignFont.label)
                        .foregroundStyle(DesignColor.textSecondary)
                    Spacer()
                    Text("\(Int(eraserWidth))")
                        .font(DesignFont.mono)
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
                    .font(DesignFont.cardTitle)
                    .foregroundStyle(DesignColor.textTertiary)

                BoostSegmented(
                    options: LassoShape.allCases.map { ($0, $0.label) },
                    selection: $lassoShape
                )

                lassoStep("1", lassoShape == .rectangle
                          ? "Trascina un rettangolo su quello che ti interessa."
                          : "Cerchia quello che ti interessa.")
                lassoStep("2", "Trascina la selezione per spostarla.")
                lassoStep("3", "Usa la barretta sopra la selezione per duplicare, copiare, tagliare o eliminare.")
                Divider()
                Text("Con qualcosa negli appunti, un tocco su un punto vuoto lo incolla lì. Funziona sull'inchiostro, non sulle caselle di testo: quelle si spostano trascinandole direttamente.")
                    .font(DesignFont.caption)
                    .foregroundStyle(DesignColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignSpace.s4)
            .frame(width: 280)
            .presentationCompactAdaptation(.popover)
        }
    }

    // Le due forme del recinto, in barra quando il lasso è in mano:
    // è una scelta che si cambia in continuazione mentre si seleziona,
    // non un'impostazione da andare a cercare.
    @ViewBuilder
    private var lassoShapeToggle: some View {
        ForEach(LassoShape.allCases) { shape in
            Button {
                lassoShape = shape
            } label: {
                toolIcon(shape.systemImage, isSelected: lassoShape == shape)
            }
            .accessibilityLabel(shape.label)
        }
    }

    private func lassoStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DesignSpace.s2) {
            Text(number)
                .font(DesignFont.caption)
                .foregroundStyle(DesignColor.brandPrimary)
                .frame(width: 16, height: 16)
                .background(DesignColor.brandPrimarySubtle, in: Circle())
            Text(text)
                .font(DesignFont.label)
                .foregroundStyle(DesignColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func toolIcon(_ systemImage: String, isSelected: Bool, tint: Color? = nil, inkColor: Color? = nil) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: DesignIcon.md))
            .foregroundStyle(isSelected ? (tint ?? DesignColor.brandPrimary) : DesignColor.textPrimary)
            .frame(width: 34, height: 34)
            .background(
                isSelected ? (tint ?? DesignColor.brandPrimary).opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
            )
            // Il trattino del colore sotto l'icona: è quello che distingue
            // penna ed evidenziatore a colpo d'occhio, molto più della
            // forma del glifo, e dice con che colore si sta scrivendo.
            .overlay(alignment: .bottom) {
                if let inkColor {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(inkColor)
                        .frame(width: 12, height: 2.5)
                        .opacity(isSelected ? 1 : 0.45)
                        .padding(.bottom, 2)
                }
            }
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
                    .font(.system(size: DesignIcon.md))
                    .foregroundStyle(DesignColor.textTertiary)
                TextField("Cerca azioni", text: $query)
                    .font(DesignFont.body)
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
                                // La tessera colorata c'è SEMPRE, come nel
                                // mock: il colore è l'identità dello
                                // strumento (Wolfram arancio, LaTeX viola…),
                                // non un modo di dire "questo è selezionato".
                                // Grigie finché non le sceglievi, le azioni
                                // erano cinque righe indistinguibili.
                                RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
                                    .fill(action.backgroundColor)
                                    .frame(width: 30, height: 30)
                                    .overlay(
                                        Image(systemName: action.systemImage)
                                            .font(.system(size: DesignIcon.sm))
                                            .foregroundStyle(action.color)
                                    )
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(action.label)
                                        .font(current == action ? DesignFont.cardTitle : DesignFont.body)
                                        .foregroundStyle(current == action ? action.color : DesignColor.textPrimary)
                                    Text(action.subtitle)
                                        .font(DesignFont.caption)
                                        .foregroundStyle(DesignColor.textTertiary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, DesignSpace.s3)
                            .padding(.vertical, DesignSpace.s3)
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
                                    .font(.system(size: DesignIcon.md))
                                    .foregroundStyle(DesignColor.danger)
                                    .frame(width: 22)
                                Text("Disattiva")
                                    .font(DesignFont.body)
                                    .foregroundStyle(DesignColor.danger)
                                Spacer()
                            }
                            .padding(.horizontal, DesignSpace.s3)
                            .padding(.vertical, DesignSpace.s3)
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
