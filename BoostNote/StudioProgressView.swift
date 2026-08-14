import SwiftUI
import SwiftData
import Charts

// Pannello "Analisi dei progressi": grafici costruiti dai record
// ExerciseAttempt registrati dal player degli esercizi. Filtrabile per
// singolo studio o su tutti.
struct StudioProgressView: View {
    let studies: [Study]
    var onBack: () -> Void

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
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Torna a Studio")

                Text("Analisi dei progressi")
                    .font(.system(size: 17, weight: .semibold))
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
            .padding(.horizontal, DesignSpace.s6 + 4)
            .frame(height: 56)
            .overlay(alignment: .bottom) {
                Rectangle().fill(DesignColor.borderDefault).frame(height: 1)
            }

            if attempts.isEmpty {
                ContentUnavailableView(
                    "Ancora nessun dato",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Svolgi qualche esercizio in uno studio: ogni autovalutazione finisce qui.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignSpace.s6) {
                        kpiRow
                        dailyChart
                        AdaptiveHVStack {
                            accuracyByDifficulty
                            topicCoverage
                        }
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
            kpiCard(value: "\(Set(attempts.map(\.topic)).count)", label: "Argomenti toccati", icon: "books.vertical", color: DesignColor.toolLatex)
        }
    }

    private func kpiCard(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: DesignSpace.s2) {
            HStack(spacing: DesignSpace.s2) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColor.textTertiary)
            }
            Text(value)
                .font(.system(size: 24, weight: .semibold))
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
                .font(.system(size: 11, weight: .semibold))
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
                .font(.system(size: 11))
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
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DesignColor.textTertiary)

            Chart(difficultyStats) { stat in
                BarMark(
                    x: .value("Accuratezza", stat.accuracy * 100),
                    y: .value("Difficoltà", stat.difficulty.label)
                )
                .foregroundStyle(stat.difficulty.color)
                .annotation(position: .trailing) {
                    Text("\(Int(stat.accuracy * 100))% · \(stat.count) es.")
                        .font(.system(size: 10))
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

    // MARK: - Copertura argomenti

    private struct TopicStat: Identifiable {
        var id: String { topic }
        var topic: String
        var total: Int
        var correct: Int
    }

    private var topicStats: [TopicStat] {
        let grouped = Dictionary(grouping: attempts) { $0.topic }
        return grouped
            .map { TopicStat(topic: $0.key, total: $0.value.count, correct: $0.value.filter(\.isCorrect).count) }
            .sorted { $0.total > $1.total }
            .prefix(6)
            .map { $0 }
    }

    private var topicCoverage: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            Text("ARGOMENTI PIÙ ESERCITATI")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DesignColor.textTertiary)

            VStack(spacing: DesignSpace.s2 + 2) {
                ForEach(topicStats) { stat in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(stat.topic)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DesignColor.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(stat.correct)/\(stat.total)")
                                .font(.system(size: 11))
                                .foregroundStyle(DesignColor.textTertiary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(DesignColor.borderSubtle)
                                Capsule()
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
