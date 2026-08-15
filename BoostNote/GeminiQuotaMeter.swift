import Foundation
import SwiftUI

// Contatore LOCALE delle chiamate Gemini, per il pannello quota.
//
// L'API del free tier NON espone la quota residua (i numeri veri stanno
// solo sulla console di AI Studio): questa è quindi una STIMA dal basso
// — conta le chiamate di QUESTA app andate a buon fine. Due fatti
// misurati la tengono onesta: i 503/429 non consumano RPD (verificato
// sulla console: RPM 4/5 con RPD 0/20), quindi si contano solo i 2xx; e
// la giornata di quota si azzera a mezzanotte del Pacifico, cioè le
// 9:00 italiane (regge anche con l'ora legale: i due fusi slittano
// insieme, salvo le settimane di bordo).
@MainActor
@Observable
final class GeminiQuotaMeter {
    static let shared = GeminiQuotaMeter()
    private static let defaultsKey = "geminiQuotaMeter.counts"

    // "giornoPacifico|modelID" → chiamate riuscite.
    private var counts: [String: Int]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            counts = decoded
        } else {
            counts = [:]
        }
    }

    private static var dayStamp: String {
        var calendar = Calendar(identifier: .gregorian)
        if let pacific = TimeZone(identifier: "America/Los_Angeles") {
            calendar.timeZone = pacific
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: .now)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    func record(_ modelID: String) {
        let day = Self.dayStamp
        counts["\(day)|\(modelID)", default: 0] += 1
        // I giorni passati non servono più: si tengono solo le chiavi di
        // oggi, così il plist non cresce per sempre.
        counts = counts.filter { $0.key.hasPrefix(day) }
        if let data = try? JSONEncoder().encode(counts) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    func todayCount(for models: [String]) -> Int {
        let day = Self.dayStamp
        return models.reduce(0) { $0 + (counts["\(day)|\($1)", default: 0]) }
    }

    // Le famiglie e i loro tetti noti (20/giorno i capaci, 500 i Lite):
    // le quote dei modelli in catena si sommano.
    static var capableModels: [String] { GeminiModelTier.full.modelChain.filter { !AIService.isLiteModel($0) } }
    static var liteModels: [String] { GeminiModelTier.lite.modelChain.filter { AIService.isLiteModel($0) } }
    static var capableLimit: Int { capableModels.count * 20 }
    static var liteLimit: Int { liteModels.count * 500 }
}

// Il pannello quota: due barre (capace/veloce) con i contatori del
// giorno. Vive dietro un pulsantino ⓘ, non in faccia all'utente.
struct GeminiQuotaPanel: View {
    private var meter = GeminiQuotaMeter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            Text("QUOTA GEMINI · FREE TIER")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DesignColor.textTertiary)

            quotaRow(
                label: "Capace",
                color: DesignColor.brandPrimary,
                used: meter.todayCount(for: GeminiQuotaMeter.capableModels),
                limit: GeminiQuotaMeter.capableLimit,
                note: "esercizi e verifica"
            )
            quotaRow(
                label: "Veloce",
                color: DesignColor.gray500,
                used: meter.todayCount(for: GeminiQuotaMeter.liteModels),
                limit: GeminiQuotaMeter.liteLimit,
                note: "riassunti, flashcard, lettura"
            )

            Text("Stima locale: conta solo le chiamate riuscite di quest'app. Le quote dei modelli in catena si sommano · azzeramento alle 9:00 italiane.")
                .font(.system(size: 11))
                .foregroundStyle(DesignColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func quotaRow(label: String, color: Color, used: Int, limit: Int, note: String) -> some View {
        HStack(spacing: DesignSpace.s2) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignColor.textPrimary)
                .frame(width: 56, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DesignColor.gray100)
                    Capsule().fill(color)
                        .frame(width: max(6, proxy.size.width * min(1, CGFloat(used) / CGFloat(max(limit, 1)))))
                }
            }
            .frame(height: 6)
            Text("\(used)/\(limit)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(DesignColor.textSecondary)
            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(DesignColor.textTertiary)
        }
    }
}
