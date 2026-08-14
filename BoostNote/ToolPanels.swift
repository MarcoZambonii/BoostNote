import SwiftUI
import SwiftData
// Timer.publish(...).autoconnect() vive in Combine: senza questo import
// il pannello Pomodoro non compila.
import Combine

// Contenuti degli strumenti del pannello laterale destro della nota.
// Tutti gli strumenti vivono qui (niente più widget flottanti sul
// foglio): il pannello resta aperto mentre si scrive e si chiude con la
// "x" — un'unica interazione coerente per tutto il catalogo.

// MARK: - Grafici (Desmos)

// Solo Desmos: potenza piena (disequazioni, implicite, slider) e barra
// delle espressioni sua. Le espressioni della penna magica passano dal
// convertitore DesmosLatex (sqrt → \sqrt{}, pi → \pi). Richiede la rete.
struct GraphPanelContent: View {
    @Binding var expression: String
    @State private var status: DesmosStatus = .loading
    @State private var reloadToken = 0

    private var expressions: [String] {
        expression
            .split(separator: ";")
            .map { DesmosLatex.convert(String($0)) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: DesignSpace.s3) {
            DesmosGraphView(expressions: expressions, status: $status, reloadToken: reloadToken)
                .frame(maxWidth: .infinity)
                // Altezza ESPLICITA: la card vive dentro la ScrollView del
                // pannello, dove maxHeight .infinity collassa a zero — la
                // webview non ha un'altezza intrinseca e Desmos si
                // caricava perfettamente… in un riquadro di 0 pixel.
                .frame(height: 460)
                .clipShape(RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DesignRadius.md).stroke(DesignColor.borderDefault))

            // Stato VERO invece della scritta fissa: prima "richiede la
            // connessione" era sempre a schermo e sembrava un errore.
            switch status {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Caricamento di Desmos…")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignColor.textTertiary)
                }
            case .ready:
                EmptyView()
            case .failed(let reason):
                VStack(spacing: DesignSpace.s2) {
                    Text(reason)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColor.danger)
                        .multilineTextAlignment(.center)
                    Button {
                        reloadToken += 1
                    } label: {
                        Label("Riprova", systemImage: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(DesignSpace.s4)
    }
}

// MARK: - To-do (persistita per nota)

struct TodoPanelContent: View {
    @Bindable var note: Note

    @State private var newText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpace.s2) {
                    ForEach(note.todoItems) { item in
                        HStack(spacing: 10) {
                            Button { toggle(item) } label: {
                                checkbox(isDone: item.isDone)
                            }
                            .buttonStyle(.plain)
                            Text(item.text)
                                .font(.system(size: 14))
                                .strikethrough(item.isDone)
                                .foregroundStyle(item.isDone ? DesignColor.textTertiary : DesignColor.textPrimary)
                            Spacer(minLength: 0)
                            Button { remove(item) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(DesignColor.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
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
        .padding(DesignSpace.s4)
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
        var items = note.todoItems
        items.append(ChecklistItem(text: trimmed))
        note.todoItems = items
        newText = ""
    }

    private func toggle(_ item: ChecklistItem) {
        var items = note.todoItems
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isDone.toggle()
        note.todoItems = items
    }

    private func remove(_ item: ChecklistItem) {
        note.todoItems = note.todoItems.filter { $0.id != item.id }
    }
}

// MARK: - Pomodoro

struct PomodoroPanelContent: View {
    @State private var totalSeconds = 25 * 60
    @State private var remainingSeconds = 25 * 60
    @State private var isRunning = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var timeLabel: String {
        String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    var body: some View {
        VStack(spacing: DesignSpace.s5) {
            Spacer()
            Text(timeLabel)
                .font(.system(size: 56, weight: .bold, design: .monospaced))
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

            Button("Reimposta") {
                isRunning = false
                remainingSeconds = totalSeconds
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(DesignColor.textSecondary)
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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

// MARK: - Wolfram Alpha

// Wolfram capisce solo la sua sintassi in inglese: da una casella vuota
// non si indovina né cosa sa fare né come chiederglielo. Questo catalogo
// serve a entrambe le cose — ogni voce è una query eseguibile con un tap.
//
// TUTTE le query qui sotto sono state eseguite contro l'API il 2026-08-12
// e restituiscono un risultato pertinente. Non aggiungerne senza averle
// provate davvero: molte formulazioni plausibili falliscono in silenzio
// (es. "step response 1/(s^2+s+1)" → success=false, mentre l'equivalente
// antitrasformata di G(s)/s funziona).
struct WolframExample: Identifiable {
    let query: String
    let label: String
    var id: String { query }
}

struct WolframCapability: Identifiable {
    let title: String
    let icon: String
    let examples: [WolframExample]
    var id: String { title }
}

struct WolframPanelContent: View {
    // Espressione con cui aprire il pannello (es. dalla penna magica):
    // viene risolta subito all'apertura.
    var prefill: String?

    static let capabilities: [WolframCapability] = [
        WolframCapability(title: "Algebra", icon: "x.squareroot", examples: [
            WolframExample(query: "solve x^2 - 5x + 6 = 0", label: "Equazioni di ogni grado"),
            WolframExample(query: "solve {2x + y = 5, x - y = 1}", label: "Sistemi di equazioni"),
            WolframExample(query: "factor x^3 - 8", label: "Fattorizzazione"),
            WolframExample(query: "expand (x+2)^5", label: "Sviluppo di potenze"),
            WolframExample(query: "simplify (x^2-1)/(x-1)", label: "Semplificazione"),
            WolframExample(query: "partial fractions 1/(x^2-1)", label: "Scomposizione in fratti semplici")
        ]),
        WolframCapability(title: "Analisi", icon: "function", examples: [
            WolframExample(query: "derivative of x^3 sin(x)", label: "Derivate"),
            WolframExample(query: "partial derivative of x^2 y^3 with respect to y", label: "Derivate parziali"),
            WolframExample(query: "integrate x^2 from 0 to 1", label: "Integrali definiti"),
            WolframExample(query: "integrate 1/(x^2+1)", label: "Integrali indefiniti"),
            WolframExample(query: "limit of sin(x)/x as x->0", label: "Limiti"),
            WolframExample(query: "taylor series e^x at x=0", label: "Sviluppi in serie"),
            WolframExample(query: "sum 1/n^2 from n=1 to infinity", label: "Serie numeriche e convergenza"),
            WolframExample(query: "local maxima of x^3 - 3x", label: "Massimi e minimi")
        ]),
        WolframCapability(title: "Equazioni differenziali", icon: "waveform.path.ecg", examples: [
            WolframExample(query: "solve y'' + 4y = 0", label: "Equazioni omogenee"),
            WolframExample(query: "solve y'' + 2y' + y = e^-t, y(0)=0, y'(0)=1", label: "Problema di Cauchy"),
            WolframExample(query: "solve y' = y(1-y)", label: "Equazioni non lineari")
        ]),
        WolframCapability(title: "Algebra lineare", icon: "square.grid.3x3", examples: [
            WolframExample(query: "eigenvalues {{1,2},{3,4}}", label: "Autovalori e autovettori"),
            WolframExample(query: "inverse {{1,2},{3,4}}", label: "Matrice inversa"),
            WolframExample(query: "determinant {{1,2,3},{4,5,6},{7,8,10}}", label: "Determinante"),
            WolframExample(query: "row reduce {{1,2,3},{4,5,6}}", label: "Riduzione a scala"),
            WolframExample(query: "rank {{1,2},{2,4}}", label: "Rango")
        ]),
        WolframCapability(title: "Controlli e Laplace", icon: "chart.xyaxis.line", examples: [
            WolframExample(query: "bode plot 100/(s^2+10s+100)", label: "Diagramma di Bode"),
            WolframExample(query: "nyquist plot 1/(s^2+s+1)", label: "Diagramma di Nyquist"),
            WolframExample(query: "poles of (s+1)/(s^2+3s+2)", label: "Poli e zeri"),
            WolframExample(query: "laplace transform sin(t)", label: "Trasformata di Laplace"),
            WolframExample(query: "inverse laplace transform 1/(s^2+1)", label: "Antitrasformata"),
            // "step response G(s)" fallisce: la risposta al gradino si
            // chiede come antitrasformata di G(s)/s.
            WolframExample(query: "inverse laplace transform 1/(s(s^2+s+1))", label: "Risposta al gradino")
        ]),
        WolframCapability(title: "Segnali e Fourier", icon: "waveform", examples: [
            WolframExample(query: "fourier transform e^(-t^2)", label: "Trasformata di Fourier"),
            WolframExample(query: "fourier series of x^2", label: "Serie di Fourier"),
            WolframExample(query: "z transform n^2", label: "Trasformata Zeta")
        ]),
        WolframCapability(title: "Probabilità e statistica", icon: "chart.bar.xaxis", examples: [
            WolframExample(query: "mean {2,4,4,4,5,5,7,9}", label: "Media, mediana, moda"),
            WolframExample(query: "standard deviation {2,4,4,4,5,5,7,9}", label: "Deviazione standard e varianza"),
            WolframExample(query: "linear fit {1,2},{2,4.1},{3,6.2}", label: "Regressione lineare"),
            WolframExample(query: "binomial distribution n=10 p=0.3", label: "Distribuzioni di probabilità"),
            WolframExample(query: "probability of 3 heads in 5 coin flips", label: "Calcolo di probabilità")
        ]),
        WolframCapability(title: "Grafici", icon: "chart.line.uptrend.xyaxis", examples: [
            WolframExample(query: "plot sin(x)/x from -10 to 10", label: "Grafico di una funzione"),
            WolframExample(query: "plot3d x^2 - y^2", label: "Superfici 3D"),
            WolframExample(query: "contour plot x^2+y^2", label: "Curve di livello")
        ]),
        WolframCapability(title: "Unità e costanti", icon: "ruler", examples: [
            WolframExample(query: "convert 50 km/h to m/s", label: "Conversioni di unità"),
            WolframExample(query: "300 K in celsius", label: "Temperature"),
            WolframExample(query: "5 N * 3 m", label: "Calcoli con unità di misura"),
            WolframExample(query: "planck constant", label: "Costanti fisiche")
        ]),
        WolframCapability(title: "Fisica ed elettrotecnica", icon: "atom", examples: [
            WolframExample(query: "kinetic energy 2 kg 3 m/s", label: "Energia e meccanica"),
            WolframExample(query: "projectile motion v=20 m/s angle=45 deg", label: "Moto del proiettile"),
            WolframExample(query: "ohms law V=10V R=200 ohm", label: "Legge di Ohm"),
            WolframExample(query: "resistors in parallel 100 ohm 220 ohm", label: "Resistenze in serie e parallelo")
        ]),
        WolframCapability(title: "Chimica", icon: "testtube.2", examples: [
            WolframExample(query: "molar mass of H2SO4", label: "Massa molare"),
            WolframExample(query: "balance Fe + O2 -> Fe2O3", label: "Bilanciamento di reazioni"),
            WolframExample(query: "properties of water", label: "Proprietà delle sostanze")
        ]),
        WolframCapability(title: "Geometria", icon: "triangle", examples: [
            WolframExample(query: "area of circle radius 3", label: "Aree"),
            WolframExample(query: "volume of sphere radius 2", label: "Volumi"),
            WolframExample(query: "distance between (1,2) and (4,6)", label: "Distanze e coordinate")
        ]),
        WolframCapability(title: "Numeri", icon: "number", examples: [
            WolframExample(query: "prime factorization 123456", label: "Fattorizzazione in primi"),
            WolframExample(query: "gcd(48, 180)", label: "MCD e mcm"),
            WolframExample(query: "convert 200 to binary", label: "Conversione tra basi"),
            WolframExample(query: "1000th prime", label: "Numeri primi")
        ]),
        WolframCapability(title: "Dati del mondo reale", icon: "globe.europe.africa", examples: [
            WolframExample(query: "population of Italy", label: "Dati statistici e demografici"),
            WolframExample(query: "distance from Milan to Rome", label: "Geografia e distanze")
        ])
    ]

    @AppStorage("wolframAlphaAppID") private var wolframAppID = ""
    @State private var expression = ""
    @State private var resultText: String?
    @State private var resultImageURLs: [URL] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    // Una categoria aperta per volta: nel pannello laterale, stretto,
    // aprirle tutte renderebbe l'elenco impraticabile da scorrere.
    @State private var expandedCapability: String?
    @State private var showingCatalog = true

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            if wolframAppID.isEmpty {
                Text("Aggiungi la tua chiave AppID nel Profilo per usare questo strumento.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignColor.textTertiary)
            } else {
                HStack(spacing: 6) {
                    TextField("Espressione da risolvere", text: $expression)
                        .font(.system(size: 14, design: .monospaced))
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(DesignSpace.s3)
                        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.md))
                        .onSubmit { Task { await solve() } }
                    if isLoading {
                        ProgressView().frame(width: 28, height: 28)
                    } else {
                        Button {
                            Task { await solve() }
                        } label: {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(DesignColor.toolWolfram)
                        }
                        .buttonStyle(.plain)
                        .disabled(expression.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignColor.danger)
                }

                // Il catalogo resta raggiungibile anche dopo un risultato
                // o un errore: è il modo per scoprire la query giusta per
                // la prossima domanda, non una schermata di benvenuto che
                // sparisce per sempre al primo tentativo.
                if !showingCatalog || hasResult {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showingCatalog.toggle() }
                    } label: {
                        Label(
                            showingCatalog ? "Nascondi cosa sa fare" : "Cosa sa fare Wolfram",
                            systemImage: showingCatalog ? "chevron.up" : "list.bullet.rectangle"
                        )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesignColor.toolWolfram)
                    }
                    .buttonStyle(.plain)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: DesignSpace.s3) {
                        if showingCatalog {
                            capabilityCatalog
                        }

                        if let resultText {
                            // Wolfram risponde con frazioni, integrali e
                            // matrici: AttributedString le lasciava come
                            // testo grezzo. KaTeX le compone davvero.
                            RichTextBlock(text: resultText)
                        }
                        ForEach(resultImageURLs, id: \.self) { url in
                            AsyncImage(url: url) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().scaledToFit()
                                } else {
                                    Color.clear.frame(height: 1)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DesignSpace.s4)
        .onAppear {
            if let prefill, !prefill.isEmpty, expression.isEmpty {
                expression = prefill
                if !wolframAppID.isEmpty {
                    Task { await solve() }
                }
            }
        }
    }

    private var hasResult: Bool {
        resultText != nil || !resultImageURLs.isEmpty
    }

    // Catalogo a fisarmonica: la categoria mostra cosa Wolfram sa fare,
    // la voce aperta mostra COME chiederglielo — ed è già la query da
    // eseguire, così l'esempio non va ricopiato a mano.
    @ViewBuilder
    private var capabilityCatalog: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s2) {
            Text("COSA SA FARE WOLFRAM")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DesignColor.textTertiary)

            ForEach(Self.capabilities) { capability in
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            expandedCapability = expandedCapability == capability.id ? nil : capability.id
                        }
                    } label: {
                        HStack(spacing: DesignSpace.s2) {
                            Image(systemName: capability.icon)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DesignColor.toolWolfram)
                                .frame(width: 18)
                            Text(capability.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DesignColor.textPrimary)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DesignColor.textTertiary)
                                .rotationEffect(.degrees(expandedCapability == capability.id ? 90 : 0))
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if expandedCapability == capability.id {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(capability.examples) { example in
                                Button {
                                    expression = example.query
                                    Task { await solve() }
                                } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(example.label)
                                            .font(.system(size: 12))
                                            .foregroundStyle(DesignColor.textSecondary)
                                        Text(example.query)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(DesignColor.toolWolfram)
                                            .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.leading, 18 + DesignSpace.s2)
                        .padding(.bottom, DesignSpace.s2)
                    }
                }
                Divider().opacity(0.35)
            }
        }
    }

    private func solve() async {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        resultText = nil
        resultImageURLs = []
        // Il risultato prende il posto del catalogo, che resta a un tap
        // di distanza col pulsante sopra.
        showingCatalog = false
        defer { isLoading = false }
        switch await MagicPenService.queryWolfram(text: trimmed, appID: wolframAppID) {
        case .success(let result):
            resultText = result.text
            resultImageURLs = result.imageURLs
        case .failure(let reason):
            errorMessage = "Wolfram Alpha: \(reason.message)"
        }
    }
}
