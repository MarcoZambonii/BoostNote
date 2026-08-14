# BoostNote

App iPad per prendere appunti e studiare, pensata per studenti di ingegneria del
Politecnico di Milano. Nasce da un'esigenza reale: scrivere a mano sulle dispense,
avere gli strumenti di calcolo a portata di penna e trasformare i materiali del
corso in percorsi di studio — senza abbonamenti e senza server da mantenere.

> Progetto personale di uno studente Polimi, in sviluppo attivo. Non affiliato al
> Politecnico di Milano né a Moodle/WeBeep.

## Cosa fa

**Appunti a pagine, con inchiostro proprio**
- Motore d'inchiostro sviluppato in-house: cattura a 240 Hz dalla Apple Pencil
  (tocchi coalescenti + predizione), resa vettoriale, sensibilità alla pressione
  con leggi di larghezza misurate empiricamente. PencilKit è usato solo come
  formato di archiviazione dei tratti, non nell'interazione.
- Penna, evidenziatore (blend multiply), gomma a oggetti, lasso con spostamento
  della selezione, undo/redo propri.
- PDF importati come pagine su cui scrivere (dispense, temi d'esame): rendering
  a piastrelle con CATiledLayer e finestra di residenza, per tenere fluide anche
  dispense da centinaia di pagine su iPad.
- Caselle di testo, immagini e formule LaTeX come oggetti modificabili sulla pagina.

**Integrazione WeBeep (Moodle Polimi)**
- Accesso con il flusso ufficiale di Moodle mobile: il login (SSO + MFA) avviene
  nel browser, l'app riceve solo il token e lo conserva nel Keychain. La password
  non transita mai dall'app né da server terzi.
- Navigazione dei corsi con la vera struttura a sezioni e moduli, anteprima,
  download e importazione dei PDF direttamente nelle note.

**Strumenti da ingegneria nel pannello laterale**
- **Wolfram Alpha**: risoluzione di espressioni (anche cerchiate a mano con la
  "penna magica"), con un catalogo di categorie verificate una per una contro
  l'API reale.
- **Grafici Desmos** incorporati, con conversione delle espressioni in LaTeX.
- **Text-to-LaTeX**: da testo naturale alla formula composta, inseribile nella
  nota come oggetto modificabile.
- **Ricerca accademica** e calcolatrice.

**Studio: dai materiali del corso a riassunti, flashcard ed esercizi**
- Generazione AI di moduli di studio (riassunti con Markdown + LaTeX, flashcard,
  esercizi con correzione) a partire da note e file WeBeep.
- Difese anti-allucinazione: le citazioni dei materiali vengono verificate
  letteralmente contro la fonte e marcate "Fonte verificata" solo se il riscontro
  esiste davvero.
- Rendering matematico con KaTeX (matrici, sistemi, ambienti LaTeX completi).

## Il vincolo architetturale: gratuita a larga scala

L'app deve poter restare gratuita anche con molti utenti. La regola è che **i
costi variabili scalano sull'utente, mai sullo sviluppatore**:

1. **AI lato client, BYOK**: ogni utente usa la propria chiave (Gemini free tier
   come default consigliato, Claude opzionale, modello Apple on-device come
   fallback senza configurazione). Nessuna chiamata LLM centralizzata.
2. **WeBeep lato client**: credenziali e token restano tra l'iPad dell'utente e
   i server di ateneo.
3. **Local-first**: dati in SwiftData sul dispositivo; nessun backend
   obbligatorio.

Di conseguenza il progetto non ha segreti nel codice: le chiavi API (Gemini,
Claude, Wolfram) le inserisce l'utente nel Profilo e vivono solo sul dispositivo.
La chiave Desmos nel codice è la chiave gratuita ufficiale che Desmos offre per
i progetti personali ([desmos.com/my-api](https://www.desmos.com/my-api)):
l'abbonamento è richiesto solo per prodotti a pagamento, e BoostNote è gratuita
per vincolo fondante.

## Architettura in breve

| Area | Scelta |
| --- | --- |
| UI | SwiftUI (iPadOS), design system in `DesignTokens.swift` |
| Persistenza | SwiftData, local-first (`Models.swift`, `StudioModels.swift`) |
| Inchiostro | Motore proprio: `PagedNoteCanvasView.swift` (cattura/pagine), `InkRenderer.swift` (resa e gomma) |
| PDF | PDFKit + CATiledLayer con LOD e residenza (±2 schermate) |
| AI | Layer provider-agnostico `AIService.swift` (Gemini / Claude / Apple on-device) |
| Matematica | KaTeX + marked in bundle locale (`BoostNote/KaTeX/`), render offline via WKWebView |
| WeBeep | `WebeepService.swift`, protocollo Moodle mobile, token nel Keychain |

`STUDIO_PLAN.md` documenta il piano e le decisioni architetturali dell'ambiente
Studio in dettaglio.

## Requisiti e avvio

- Xcode 16+, iPadOS 18+; pensata per iPad con Apple Pencil.
- Aprire `BoostNote.xcodeproj`, selezionare un iPad (fisico o simulatore) e
  lanciare. Nessuna dipendenza esterna da risolvere: le librerie web sono in
  bundle e tutto il resto è framework di sistema.
- Per le funzioni AI: inserire la propria chiave nel Profilo dell'app
  (Gemini: gratuita su [aistudio.google.com](https://aistudio.google.com);
  Wolfram: AppID gratuito su [developer.wolframalpha.com](https://developer.wolframalpha.com)).

## Licenze di terze parti

Il bundle include KaTeX 0.16.11 e marked 12.0.2, entrambe con licenza MIT:
vedi [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
