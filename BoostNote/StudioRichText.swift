import SwiftUI

// Testo generato dall'AI reso come contenuto formattato: Markdown
// (grassetti, elenchi, titoli) e formule matematiche in vera notazione.
//
// È un involucro su `RichTextView` (KaTeX + marked impacchettati
// nell'app, tutto offline). Una versione precedente spezzava il testo in
// blocchi e mandava a KaTeX solo le formule su riga propria tra `$$`;
// `RichTextView` risolve anche la matematica dentro una frase, quindi
// quel parser è stato buttato.
//
// PERCORSO VELOCE: ogni istanza di RichTextView è una WKWebView, costosa
// se la schermata ne mostra molte insieme (un mazzo di punti di ripasso
// arriva a decine). La maggior parte delle stringhe brevi — una domanda,
// il titolo di una sezione, il fronte di una flashcard — non contiene né
// formule né Markdown: lì si usa un normale `Text`, che è gratis. La
// WebView entra in gioco solo quando serve davvero.
struct StudioRichText: View {
    let text: String
    // Ruolo tipografico del percorso veloce (il ramo WebView compone con
    // il CSS del template e non lo legge): dai DesignFont, mai size raw.
    var font: Font = DesignFont.body
    var color: Color = DesignColor.textSecondary

    @State private var height: CGFloat = 20

    var body: some View {
        if Self.needsRichRendering(text) {
            RichTextView(text: text, height: $height)
                .frame(height: height)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineSpacing(DesignFont.bodyLineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Il testo contiene qualcosa che vale una WebView? Si guardano i
    // delimitatori LaTeX e i segni Markdown che cambiano davvero la resa.
    // In dubbio si sceglie il rendering ricco: mostrare "$$x^2$$" come
    // testo è molto peggio che spendere una WebView di troppo.
    static func needsRichRendering(_ text: String) -> Bool {
        if text.contains("$") { return true }                 // $…$ e $$…$$
        if text.contains("\\(") || text.contains("\\[") { return true }
        if text.contains("\\frac") || text.contains("\\int") || text.contains("\\sum") { return true }
        // Matrici e sistemi scritti nudi, senza $$: il template li
        // riconosce e li compone lo stesso, ma solo se ci arrivano.
        if text.contains("\\begin{") { return true }
        if text.contains("**") || text.contains("__") { return true }  // grassetto
        if text.contains("`") { return true }                 // codice
        // Elenchi e titoli: solo a inizio riga, altrimenti un trattino in
        // mezzo a una frase farebbe scattare il renderer per niente.
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("#") { return true }
            if let first = trimmed.first, first.isNumber, trimmed.dropFirst().hasPrefix(". ") { return true }
        }
        return false
    }
}
