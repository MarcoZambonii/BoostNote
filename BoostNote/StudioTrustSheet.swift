import SwiftUI

// Pannello "Come funziona la generazione".
//
// REGOLA DI SCRITTURA DI QUESTA SCHERMATA — non cambiarla senza pensarci:
// qui si elencano SOLO i meccanismi realmente attivi nella build e nello
// studio corrente, letti dallo stato vero (provider configurato, verifica
// accesa, chiave Wolfram presente), mai dal piano di ciò che vorremmo
// fare. E non si promette infallibilità: le difese riducono molto gli
// errori, nessuna li elimina. Promettere a uno studente che l'app "non
// può sbagliare" significa perdere tutta la sua fiducia il giorno in cui
// trova una soluzione sbagliata — cioè esattamente la sera prima di un
// esame. La fiducia giustificata è più solida di quella promessa.
struct StudioTrustSheet: View {
    @Environment(\.dismiss) private var dismiss
    let study: Study

    @AppStorage("wolframAlphaAppID") private var wolframAppID = ""

    // La verifica è un'opzione per modulo: qui interessa se è accesa sul
    // modulo esercizi di QUESTO studio.
    private var verificationOn: Bool {
        study.sortedModules.contains { $0.kind == .exercises && $0.options.verifyExercises }
    }

    private var hasExercises: Bool {
        study.sortedModules.contains { $0.kind == .exercises }
    }

    // Il provider registrato al momento della generazione, non quello
    // selezionato adesso: cambiare impostazione non deve riscrivere la
    // storia di contenuti già prodotti.
    private var generatorLabel: String {
        study.sortedModules.first { $0.generatedByRaw != "none" && $0.generatedByRaw != "mock" }?.generatedByRaw ?? AIService.selectedProvider.label
    }

    private var usesRealAI: Bool {
        study.sortedModules.contains { $0.generatedByRaw != "none" && $0.generatedByRaw != "mock" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSpace.s6) {
                    intro

                    section(title: "I CONTROLLI ATTIVI SU QUESTO STUDIO") {
                        VStack(alignment: .leading, spacing: DesignSpace.s3) {
                            check(
                                on: true,
                                title: "Genera solo dai tuoi materiali",
                                detail: "Il modello riceve il testo dei documenti che hai scelto e l'istruzione esplicita di non aggiungere teoria propria. Se una cosa non è nei materiali, deve dire che non c'è."
                            )
                            check(
                                on: true,
                                title: "Ogni contenuto cita la fonte, e la citazione viene controllata",
                                detail: "Il modello deve riportare un passaggio copiato alla lettera dai tuoi materiali. L'app cerca quel passaggio nel testo originale: se non lo trova, il contenuto viene marcato in arancione come non verificato. È un controllo automatico, non un'altra opinione dell'AI."
                            )
                            check(
                                on: true,
                                title: "Ciò che non rispetta il formato viene scartato",
                                detail: AIService.selectedProvider == .gemini
                                    ? "Con Gemini lo schema della risposta viene imposto al modello già durante la generazione, e l'app la ricontrolla comunque al ritorno: quello che non lo rispetta non ti viene mostrato."
                                    : "Le risposte vengono decodificate secondo uno schema rigido: quello che non lo rispetta non ti viene mostrato, si rigenera."
                            )
                            if hasExercises {
                                check(
                                    on: verificationOn,
                                    title: "Ogni esercizio viene risolto due volte",
                                    detail: verificationOn
                                        ? "Una seconda richiesta indipendente rifà gli esercizi e fa da correttore: quelli in cui le due soluzioni non coincidono vengono scartati, non mostrati con un avviso."
                                        : "Disattivato per questo studio: gli esercizi non sono stati ricontrollati da un secondo passaggio. Puoi attivarlo creando un nuovo studio."
                                )
                                check(
                                    on: !wolframAppID.isEmpty,
                                    title: "Verifica dei risultati fuori dall'AI",
                                    detail: wolframAppID.isEmpty
                                        ? "Aggiungi la chiave Wolfram Alpha nel Profilo: gli esercizi con un risultato calcolabile potranno essere verificati da un motore di calcolo, che non è un modello linguistico e non inventa."
                                        : "Gli esercizi con un risultato calcolabile hanno un pulsante che lo fa ricalcolare a Wolfram Alpha — un motore di calcolo, non un modello linguistico."
                                )
                            }
                        }
                    }

                    section(title: "COME VENGONO SCELTI I MODELLI") {
                        VStack(alignment: .leading, spacing: DesignSpace.s3) {
                            modelPicking
                        }
                    }

                    limits

                    section(title: "DOVE FINISCONO I TUOI MATERIALI") {
                        Text(privacyText)
                            .font(.system(size: 13))
                            .foregroundStyle(DesignColor.textSecondary)
                            .lineSpacing(2)
                    }
                }
                .padding(DesignSpace.s6)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(DesignColor.surfacePage)
            .navigationTitle("Come funziona la generazione")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s2) {
            Text(usesRealAI
                 ? "I contenuti di questo studio sono stati generati con \(generatorLabel) a partire dai materiali che hai scelto."
                 : "I moduli di questo studio non sono ancora stati generati: apri una card per vedere cosa è andato storto e riprovare.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DesignColor.textPrimary)
                .lineSpacing(2)
            Text("Qui sotto trovi esattamente quali controlli sono attivi, e cosa restano comunque da verificare.")
                .font(.system(size: 13))
                .foregroundStyle(DesignColor.textTertiary)
        }
    }

    // La parte che non va addolcita: il limite dichiarato apertamente è
    // ciò che rende credibile tutto il resto della schermata.
    private var limits: some View {
        VStack(alignment: .leading, spacing: DesignSpace.s2) {
            Label("Cosa non possiamo garantire", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignColor.toolWolfram)
            Text("Questi controlli riducono molto gli errori, ma non li eliminano. Un modello può leggere male una formula, attribuire un enunciato alla sezione sbagliata o produrre una soluzione che sembra corretta e non lo è. Prima di un esame, considera i contenuti generati un aiuto al ripasso, non una fonte da citare: la fonte restano i tuoi materiali, che sono sempre a un tocco di distanza dalla citazione.")
                .font(.system(size: 13))
                .foregroundStyle(DesignColor.textSecondary)
                .lineSpacing(2)
            Text("Se trovi qualcosa di sbagliato, usa “Segnala errore” sul contenuto: resta evidenziato e puoi rigenerare il modulo.")
                .font(.system(size: 13))
                .foregroundStyle(DesignColor.textSecondary)
                .lineSpacing(2)
        }
        .padding(DesignSpace.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignColor.toolWolframBg, in: RoundedRectangle(cornerRadius: DesignRadius.lg, style: .continuous))
    }

    // Come vengono scelti i modelli: stessa regola del resto della
    // schermata — si descrive la catena REALE, letta da GeminiModelTier,
    // non un'idea di catena. Solo Gemini ne ha una; gli altri provider
    // dicono onestamente di essere un modello solo.
    @ViewBuilder
    private var modelPicking: some View {
        switch AIService.selectedProvider {
        case .appleLocal:
            info(
                icon: "ipad",
                title: "Un solo modello, sul tuo iPad",
                detail: "Con il modello Apple locale non c'è una catena: tutto avviene sul dispositivo, anche senza rete. È il motivo per cui funziona sempre, e anche il motivo dei suoi limiti sui compiti complessi."
            )
        case .claude:
            info(
                icon: "link",
                title: "Un solo modello, con la tua chiave Anthropic",
                detail: "Claude non ha modelli di riserva: se la chiamata fallisce, il modulo riporta il motivo e puoi riprovare."
            )
        case .gemini:
            let capable = GeminiModelTier.full.modelChain
            let fast = GeminiModelTier.lite.modelChain
            info(
                icon: "arrow.triangle.branch",
                title: "Una catena di modelli, non uno solo",
                detail: "Gli esercizi e la loro verifica partono dal modello più capace (\(capable.first ?? "")); riassunti, flashcard, ripasso e lettura dal più veloce (\(fast.first ?? "")). Se un modello è pieno o non risponde si passa al successivo — in tutto \(capable.count) modelli, e le loro quote giornaliere si sommano."
            )
            info(
                icon: "clock.badge.exclamationmark",
                title: "Quota finita e ingorgo non sono la stessa cosa",
                detail: "La quota giornaliera di ogni modello si azzera alle 9 del mattino italiane (mezzanotte in California). Un modello \"sovraccarico\" è invece un ingorgo momentaneo dei server di Google: passa in pochi minuti e non consuma la tua quota. Se un modulo esce dal modello veloce, la card ti dice quale delle due cose è successa."
            )
            info(
                icon: "brain",
                title: "Il ragionamento è acceso solo dove serve",
                detail: "Solo gli esercizi e la loro verifica usano il tempo di ragionamento del modello: è ciò che li rende problemi con dati da applicare invece di domande di definizione. Gli altri moduli lo tengono spento, e per questo arrivano in pochi secondi."
            )
            info(
                icon: "timer",
                title: "Mai più di tre minuti per modulo",
                detail: "Ogni modulo ha un tetto di tempo complessivo: scaduto quello, la generazione si ferma con un errore chiaro invece di girare a vuoto. Mentre genera, la card mostra quale modello sta provando e puoi annullare in ogni momento."
            )
        }
    }

    private var privacyText: String {
        switch AIService.selectedProvider {
        case .appleLocal:
            "La generazione avviene interamente sul tuo iPad con il modello di sistema di Apple: i materiali non escono dal dispositivo."
        case .gemini:
            "Il testo dei materiali — e, per le note scritte a mano, l'immagine delle pagine da trascrivere — viene inviato a Google con la tua chiave personale, direttamente dal tuo iPad: non passa da nessun server di BoostNote. Sul piano gratuito di Gemini, Google può usare i contenuti inviati per migliorare i propri modelli — tienilo presente con materiale riservato."
        case .claude:
            "Il testo dei materiali — e, per le note scritte a mano, l'immagine delle pagine da trascrivere — viene inviato ad Anthropic con la tua chiave personale, direttamente dal tuo iPad: non passa da nessun server di BoostNote."
        }
    }

    @ViewBuilder
    private func section(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DesignSpace.s3) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DesignColor.textTertiary)
            content()
        }
    }

    // Riga informativa: come `check`, ma per fatti che non sono
    // controlli attivabili — icona in blu invece della spunta verde.
    private func info(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DesignSpace.s3) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(DesignColor.brandPrimary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignColor.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColor.textTertiary)
                    .lineSpacing(2)
            }
        }
    }

    private func check(on: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DesignSpace.s3) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 16))
                .foregroundStyle(on ? DesignColor.success : DesignColor.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(on ? DesignColor.textPrimary : DesignColor.textSecondary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignColor.textTertiary)
                    .lineSpacing(2)
            }
        }
    }
}
