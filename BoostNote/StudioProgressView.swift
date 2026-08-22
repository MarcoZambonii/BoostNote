import SwiftUI
import SwiftData
import Charts

// Pannello "Analisi dei progressi": grafici costruiti dai record
// ExerciseAttempt registrati dal player degli esercizi. Filtrabile per
// singolo studio o su tutti.
struct StudioProgressView: View {
    let studies: [Study]
    var onBack: () -> Void
    // Chiude il cerchio: dai risultati a un nuovo studio mirato sugli
    // argomenti andati peggio.
    var onGenerateWeak: ((StudyFolder, [String]) -> Void)?

    @Query(sort: \ExerciseAttempt.date) private var allAttempts: [ExerciseAttempt]

    @State private var filterStudy: Study?

    private var attempts: [ExerciseAttempt] {
        guard let filterStudy else { return allAttempts }
        return allAttempts.filter { $0.study === filterStudy }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSpace.s3) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: DesignIcon.md))
                        .foregroundStyle(DesignColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Torna a Studio")

                Text("Analisi dei progressi")
                    .font(DesignFont.cardTitle)
                    .foregroundStyle(DesignColor.textPrimary)
                Spacer()
                Picker("Studio", selection: $filterStudy) {
                    Text("Tutti gli studi").tag(Study?.none)
                    ForEach(studies) { study in
                        Text(study.name).tag(Study?.some(study))
                    }
                }
                .pickerStyle(.menu)
                .tint(DesignColor.brandPrimary)
            }
            .padding(.horizontal, DesignSpace.s6)
            .frame(height: 56)
            .overlay(alignment: .bottom) {
                Rectangle().fill(DesignColor.borderDefault).frame(height: 1)
            }

            if attempts.isEmpty {
                BoostState(
                    kind: .empty,
                    icon: "chart.bar",
                    title: "Ancora nessun dato",
                    message: "Svolgi qualche esercizio in uno studio: ogni autovalutazione finisce qui."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignSpace.s6) {
                        kpiRow
                        weakTopicsCard
                        dailyChart
                        AdaptiveHVStack {
                            accuracyByDifficulty
                            accuracyByCategory
                        }
                        topicCoverage
                    }
                    .padding(DesignSpace.s6)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - KPI

    private var correctCount: Int { attempts.filter(\.isCorrect).count }

    private var accuracy: Double {
        attempts.isEmpty ? 0 : Double(correctCount) / Double(attempts.count)
    }

    private var totalMinutes: Int {
        Int(attempts.map(\.durationSeconds).reduce(0, +) / 60)
    }

    private var kpiRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: DesignSpace.s4)], spacing: DesignSpace.s4) {
            kpiCard(value: "\(attempts.count)", label: "Esercizi svolti", icon: "pencil.and.list.clipboard", color: DesignColor.brandPrimary)
            kpiCard(value: "\(Int(accuracy * 100))%", label: "Accuratezza", icon: "target", color: accuracy >= 0.6 ? DesignColor.success : DesignColor.danger)
            kpiCard(value: totalMinutes < 60 ? "\(totalMinutes) min" : String(format: "%.1f h", Double(totalMinutes) / 60), label: "Tempo sugli esercizi", icon: "clock", color: DesignColor.toolSearch)
            kpiCard(value: "\(Set(attempts.map(\.topic)).count)", label: "Argomenti toccati", icon: "books.vertical", color: DesignColor.insight)
        }
    }

    private func kpiCard(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: DesignSpace.s2) {
            HStack(spacing: DesignSpace.s2) {
                Image(systemName: icon)
                    .font(.system(size: DesignIcon.md))
                    .foregroundStyle(color)
                Text(label)
                    .font(DesignFont.caption)
                    .foregroundStyle(DesignColor.textTertiary)
            }
            Text(value)
                .font(DesignFont.display)
                .foregroundStyle(DesignColor.textPrimary)
        }
        .padding(DesignSpace.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
    }

    // MARK: - Esercizi per giorno (ultime 2 settimane)

    private struct DayBucket: Identifiable {
        var id: Date { day }
        var day: Date
        var correct: Int
        var wrong: Int
    }

    private var dailyBuckets: [DayBucket] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -13, to: .now) ?? .now)
        var buckets: [Date: (correct: Int, wrong: Int)] = [:]
        for offset in 0..<14 {
            if let day = calendar.date(byAdding: .day, value: offset, to: start) {
                buckets[day] = (0, 0)
            }
        }
        for attempt in attempts {
            let day = calendar.startOfDay(for: attempt.date)
            guard day >= start else { continue }
            var bucket = buckets[day] ?? (0, 0)
            if attempt.isCorrect { bucket.correct += 1 } else { bucket.wrong += 1 }
            buckets[day] = bucket
        }
        return buckets.keys.sorted().map { DayBucket(day: $0, correct: buckets[$0]?.correct ?? 0, wrong: buckets[$0]?.wrong ?? 0) }
    }

    private var dailyChart: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            Text("ESERCIZI PER GIORNO — ULTIME 2 SETTIMANE")
                .font(DesignFont.micro)
                .tracking(0.6)
                .foregroundStyle(DesignColor.textTertiary)

            Chart(dailyBuckets) { bucket in
                BarMark(
                    x: .value("Giorno", bucket.day, unit: .day),
                    y: .value("Giusti", bucket.correct)
                )
                .foregroundStyle(DesignColor.success)
                BarMark(
                    x: .value("Giorno", bucket.day, unit: .day),
                    y: .value("Sbagliati", bucket.wrong)
                )
                .foregroundStyle(DesignColor.danger.opacity(0.55))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .frame(height: 180)

            HStack(spacing: DesignSpace.s4) {
                legendDot(color: DesignColor.success, label: "Giusti")
                legendDot(color: DesignColor.danger.opacity(0.55), label: "Sbagliati")
            }
        }
        .padding(DesignSpace.s5)
        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(DesignFont.caption)
                .foregroundStyle(DesignColor.textTertiary)
        }
    }

    // MARK: - Accuratezza per difficoltà

    private struct DifficultyStat: Identifiable {
        var id: String { difficulty.rawValue }
        var difficulty: ExerciseDifficulty
        var accuracy: Double
        var count: Int
    }

    private var difficultyStats: [DifficultyStat] {
        ExerciseDifficulty.allCases.compactMap { level in
            let subset = attempts.filter { $0.difficulty == level }
            guard !subset.isEmpty else { return nil }
            let correct = subset.filter(\.isCorrect).count
            return DifficultyStat(difficulty: level, accuracy: Double(correct) / Double(subset.count), count: subset.count)
        }
    }

    private var accuracyByDifficulty: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            Text("ACCURATEZZA PER DIFFICOLTÀ")
                .font(DesignFont.micro)
                .tracking(0.6)
                .foregroundStyle(DesignColor.textTertiary)
            // I teorici non compaiono qui, e non per una svista: una
            // difficoltà non ce l'hanno (`difficulty` è nil e il filtro
            // qui sotto non li prende). Dirlo evita che la somma di questo
            // riquadro sembri sbagliata rispetto ai totali in alto.
            if attempts.contains(where: { $0.difficulty == nil }) {
                Text("Solo esercizi da risolvere: i teorici non hanno un livello.")
                    .font(DesignFont.caption)
                    .foregroundStyle(DesignColor.textTertiary)
            }

            Chart(difficultyStats) { stat in
                BarMark(
                    x: .value("Accuratezza", stat.accuracy * 100),
                    y: .value("Difficoltà", stat.difficulty.label)
                )
                .foregroundStyle(stat.difficulty.color)
                .annotation(position: .trailing) {
                    Text("\(Int(stat.accuracy * 100))% · \(stat.count) es.")
                        .font(DesignFont.micro)
                        .foregroundStyle(DesignColor.textTertiary)
                }
            }
            .chartXScale(domain: 0...110)
            .chartXAxis(.hidden)
            .frame(height: CGFloat(max(difficultyStats.count, 1)) * 44)
        }
        .padding(DesignSpace.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
    }

    // MARK: - Teoria e pratica

    private struct CategoryStat: Identifiable {
        var id: String { category.rawValue }
        var category: ExerciseCategory
        var accuracy: Double
        var count: Int
    }

    // Le due metà dello studio, con i nomi dei moduli da cui arrivano
    // (ExerciseCategory.label): saper risolvere e saper spiegare sono
    // bravure diverse, e questa è la riga che dice se ne stai allenando
    // una sola.
    private var categoryStats: [CategoryStat] {
        ExerciseCategory.allCases.compactMap { category in
            let subset = attempts.filter { $0.category == category }
            guard !subset.isEmpty else { return nil }
            let correct = subset.filter(\.isCorrect).count
            return CategoryStat(category: category, accuracy: Double(correct) / Double(subset.count), count: subset.count)
        }
    }

    private var accuracyByCategory: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            Text("TEORIA E PRATICA")
                .font(DesignFont.micro)
                .tracking(0.6)
                .foregroundStyle(DesignColor.textTertiary)

            if categoryStats.count < 2 {
                Text("Qui il confronto compare quando hai svolto sia esercizi da risolvere sia esercizi teorici: sapere risolvere e sapere spiegare sono due bravure diverse, e vale la pena vederle affiancate.")
                    .font(DesignFont.caption)
                    .foregroundStyle(DesignColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Chart(categoryStats) { stat in
                BarMark(
                    x: .value("Accuratezza", stat.accuracy * 100),
                    y: .value("Tipo", stat.category.label)
                )
                .foregroundStyle(stat.category == .practical ? DesignColor.toolWolfram : DesignColor.toolExplain)
                .annotation(position: .trailing) {
                    Text("\(Int(stat.accuracy * 100))% · \(stat.count)")
                        .font(DesignFont.micro)
                        .foregroundStyle(DesignColor.textTertiary)
                }
            }
            .chartXScale(domain: 0...110)
            .chartXAxis(.hidden)
            .frame(height: CGFloat(max(categoryStats.count, 1)) * 44)
        }
        .padding(DesignSpace.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
    }

    // MARK: - Copertura argomenti

    // L'etichetta da mostrare per un gruppo di tentativi: la più
    // specifica (più parole), a parità la più recente. Le varianti sono
    // la stessa cosa, ma allo studente si fa vedere quella che dice di
    // più.
    private static func displayLabel(of attempts: [ExerciseAttempt]) -> String {
        attempts
            .map(\.topic)
            .filter { !$0.isEmpty }
            .max { TopicKey.tokens($0).count < TopicKey.tokens($1).count } ?? ""
    }

    private struct TopicStat: Identifiable {
        var id: String { topic }
        var topic: String
        var total: Int
        var correct: Int
    }

    private var topicStats: [TopicStat] {
        // Raggruppamento sulla CHIAVE canonica, non sulla stringa nuda:
        // "problemi di trasporto" e "problema di trasporto" sono lo
        // stesso argomento e devono fare una riga sola. L'etichetta
        // mostrata è la più specifica del gruppo.
        let grouped = Dictionary(grouping: attempts) { TopicKey.key($0.topic) }
        return grouped
            .map { TopicStat(topic: Self.displayLabel(of: $0.value), total: $0.value.count, correct: $0.value.filter(\.isCorrect).count) }
            .sorted { $0.total > $1.total }
            .prefix(6)
            .map { $0 }
    }

    // MARK: - Argomenti deboli → nuovo studio mirato
    //
    // Questa card esiste perché gli argomenti sono diventati un
    // vocabolario stabile: prima il modello se li inventava a ogni
    // generazione ("dualità in PL" / "problema duale") e raggrupparli su
    // una stringa libera dava statistiche frantumate, inutili per
    // decidere su cosa insistere. Con l'indice del Vault le percentuali
    // per argomento sono confrontabili, e quindi azionabili.
    //
    // Due soglie, entrambe prudenti: sotto il 60% di risposte corrette,
    // e almeno 3 tentativi — un argomento sbagliato una volta sola non è
    // una debolezza, è un caso.
    private struct WeakTopic {
        let topic: String
        let correct: Int
        let total: Int
        let folder: StudyFolder
        var accuracy: Double { Double(correct) / Double(max(total, 1)) }
    }

    private var weakTopics: [WeakTopic] {
        // Un argomento appartiene al Vault dello studio in cui è stato
        // esercitato: senza cartella non si saprebbe da dove rigenerare.
        let grouped = Dictionary(grouping: attempts.filter { $0.study?.folder != nil }) { TopicKey.key($0.topic) }
        return grouped.compactMap { key, items -> WeakTopic? in
            let topic = Self.displayLabel(of: items)
            guard !key.isEmpty, !topic.isEmpty, items.count >= 3,
                  let folder = items.compactMap({ $0.study?.folder }).last else { return nil }
            let correct = items.filter(\.isCorrect).count
            let stat = WeakTopic(topic: topic, correct: correct, total: items.count, folder: folder)
            return stat.accuracy < 0.6 ? stat : nil
        }
        .sorted { $0.accuracy < $1.accuracy }
    }

    @ViewBuilder
    private var weakTopicsCard: some View {
        let weak = weakTopics
        if !weak.isEmpty, let folder = weak.first?.folder {
            // Un solo Vault per volta: mescolare argomenti di corsi
            // diversi in uno studio non avrebbe senso. Si prende quello
            // dell'argomento più debole e si tengono i suoi.
            let sameVault = weak.filter { $0.folder.id == folder.id }.prefix(5)
            VStack(alignment: .leading, spacing: DesignSpace.s3) {
                HStack(spacing: DesignSpace.s2) {
                    Image(systemName: "target")
                        .font(.system(size: DesignIcon.md))
                        .foregroundStyle(DesignColor.danger)
                    Text("DOVE SEI PIÙ IN DIFFICOLTÀ")
                        .font(DesignFont.micro)
                        .tracking(0.6)
                        .foregroundStyle(DesignColor.textTertiary)
                    Spacer()
                    Text(folder.name)
                        .font(DesignFont.caption)
                        .foregroundStyle(DesignColor.textTertiary)
                }
                VStack(spacing: DesignSpace.s2) {
                    ForEach(Array(sameVault), id: \.topic) { stat in
                        HStack(spacing: DesignSpace.s3) {
                            Text(stat.topic)
                                .font(DesignFont.label)
                                .foregroundStyle(DesignColor.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: DesignSpace.s3)
                            Text("\(Int(stat.accuracy * 100))%")
                                .font(DesignFont.cardTitle.monospacedDigit())
                                .foregroundStyle(DesignColor.danger)
                            Text("\(stat.correct)/\(stat.total)")
                                .font(DesignFont.caption.monospacedDigit())
                                .foregroundStyle(DesignColor.textTertiary)
                        }
                    }
                }
                if let onGenerateWeak {
                    Button {
                        onGenerateWeak(folder, sameVault.map(\.topic))
                    } label: {
                        Label("Genera esercizi su questi argomenti", systemImage: "sparkles")
                            .font(DesignFont.cardTitle)
                            .foregroundStyle(DesignColor.textOnBrand)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DesignSpace.s3)
                            .background(DesignColor.brandPrimary, in: RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    Text("Nuovo studio dal Vault “\(folder.name)”, con questi argomenti già selezionati e solo il modulo esercizi.")
                        .font(DesignFont.caption)
                        .foregroundStyle(DesignColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DesignSpace.s5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignColor.dangerBg.opacity(0.5), in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
        }
    }

    private var topicCoverage: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            Text("ARGOMENTI PIÙ ESERCITATI")
                .font(DesignFont.micro)
                .tracking(0.6)
                .foregroundStyle(DesignColor.textTertiary)

            VStack(spacing: DesignSpace.s2 + 2) {
                ForEach(topicStats) { stat in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(stat.topic)
                                .font(DesignFont.caption)
                                .foregroundStyle(DesignColor.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(stat.correct)/\(stat.total)")
                                .font(DesignFont.caption)
                                .foregroundStyle(DesignColor.textTertiary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous).fill(DesignColor.borderSubtle)
                                RoundedRectangle(cornerRadius: DesignRadius.sm, style: .continuous)
                                    .fill(DesignColor.brandPrimary)
                                    .frame(width: geo.size.width * CGFloat(stat.correct) / CGFloat(max(stat.total, 1)))
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
        .padding(DesignSpace.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignColor.surfaceSunken, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
    }
}
