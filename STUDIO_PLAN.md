# Piano di lavoro — Ambiente "Studio"

Stato: la v1 della schermata è implementata e funzionante con generazione **mock**;
il layer AI provider-agnostico (`AIService.swift`) è attivo e la generazione reale
parte da sola quando un provider è configurato nel Profilo.
Questo documento tiene il piano complessivo, l'architettura per la generazione AI
reale e per i temi d'esame da WeBeep, e le raccomandazioni sui punti aperti.

## 0. Vincolo architetturale: gratuità a larga scala

L'app deve restare gratuita anche con molti utenti: **i costi variabili scalano con
l'utente, non con lo sviluppatore**. In pratica:

1. **Inferenza AI lato client** (`AIService.swift`): Gemini free tier come default
   consigliato (chiave gratuita che l'utente crea su aistudio.google.com), BYOK
   opzionale (Claude), modello Apple locale come fallback zero-config. Nessuna
   chiamata LLM centralizzata.
2. **WeBeep lato client**: le credenziali Polimi non transitano mai da un server
   proprio (già così: flusso Moodle mobile, token in Keychain).
3. **Local-first**: dati sul dispositivo (SwiftData); sync opzionale via Drive
   dell'utente; backend minimo (free tier Supabase/Cloudflare) solo per auth e
   feature community, quando/se serviranno.
4. **Premium aggiungibile senza ristrutturare** (es. doppio passaggio "correttore"
   sempre attivo, generazioni batch), ma il core di studio resta gratuito.

## 1. Cosa esiste già (v1, agosto 2026)

| File | Ruolo |
| --- | --- |
| `BoostNote/StudioModels.swift` | SwiftData: `Study`, `StudyModule`, `ExerciseAttempt` + payload Codable dei moduli |
| `BoostNote/StudioGenerationService.swift` | Generazione mock; unico seam (`generateContent`) dove innestare l'AI reale |
| `BoostNote/StudioEnvironmentView.swift` | Sidebar "Studi" per materia (o strip compatta sotto 620pt) + switching pannelli |
| `BoostNote/StudioCreateFlow.swift` | Flusso "Crea nuovo studio": nome/materia → materiali (note, WeBeep, PDF) → moduli+opzioni |
| `BoostNote/StudyDetailView.swift` | Dettaglio studio + viewer: Riassunto, player Esercizi (soluzione guidata, autovalutazione), Punti di ripasso, Flashcard |
| `BoostNote/StudioProgressView.swift` | Analisi dei progressi (Swift Charts) da `ExerciseAttempt` |

Principi architetturali:
- **Moduli estensibili**: un tipo nuovo = un caso in `StudyModuleKind` + un payload
  Codable + un viewer. Il contenuto vive in `contentJSON` (pattern `NoteWidget.dataJSON`),
  quindi niente migrazioni di schema.
- **Materiali come metadati** (`StudySourceMaterial`): le note per UUID, WeBeep/PDF per
  titolo. Il testo si risolve al momento della generazione (`resolveSources`).
- **Progressi denormalizzati**: ogni autovalutazione scrive un `ExerciseAttempt`
  (argomento, difficoltà, categoria, durata, esito) — i grafici non rileggono i moduli.

## 2. Prossimi passi in ordine di dipendenza

1. **Estrazione testo dai PDF** (PDFKit, `PDFDocument.string`): prerequisito per
   generare da slide/dispense/temi d'esame veri. Copiare il PDF nello studio
   (`.externalStorage`) al momento della selezione, non tenerne solo il titolo.
2. **Download WeBeep nel flusso di creazione**: oggi si prendono solo i metadati;
   riusare `WebeepService.downloadFile` alla conferma, con gli stessi errori parlanti.
3. **Generazione AI reale** dietro il seam (vedi §3): FATTO in prima versione —
   `AIService` (Gemini free tier / Claude BYOK / Apple locale, selezione nel Profilo)
   con grounding e JSON validato, fallback automatico al mock. Mancano: doppio
   passaggio "correttore", citazioni con `sourceRange`, pulsante "Segnala errore".
4. **Spaced repetition sulle flashcard** (SM-2 semplificato): aggiungere al payload
   `Flashcard` i campi `easiness/interval/dueDate` e un filtro "da ripassare oggi".
   È la voce storica del backlog: ora ha una base su cui poggiare.
5. **Collegamento nota → studio** (idea già in backlog): pulsante nella nota che apre
   lo studio che la usa come materiale (ricerca per `noteID` nei `sources`).
6. **Rigenerazione mirata / aggiunta moduli a studio esistente** (il menu contestuale
   "Rigenera" c'è già; manca "aggiungi modulo" dopo la creazione).

## 3. Generazione AI precisa e non allucinata

Il rischio vero per un'app di studio è generare cose *plausibili ma sbagliate*.
Linee guida per l'implementazione dietro `StudioGenerationService.generateContent`:

1. **Grounding stretto**: il prompt include SOLO il testo estratto dai materiali,
   con istruzione esplicita "usa esclusivamente questo testo; se l'informazione non
   c'è, dillo". Mai chiedere al modello di 'completare' la teoria da conoscenza propria
   per i riassunti/punti di ripasso.
2. **Citazioni obbligatorie**: ogni sezione di riassunto / punto di ripasso / risposta
   porta un riferimento al materiale e (quando possibile) alla pagina — il payload ha
   già `sourceTitle`; aggiungere `sourceRange`. In UI, un tap mostra il passaggio
   originale accanto alla generazione: l'utente verifica in un colpo d'occhio.
3. **Output strutturato**: chiedere JSON conforme ai payload Codable (schema nel
   prompt) e validare col decoder: ciò che non decodifica si scarta e si rigenera,
   non si mostra.
4. **Doppio passaggio per gli esercizi**: (a) genera esercizio+soluzione; (b) seconda
   chiamata "da correttore" che risolve l'esercizio da zero e confronta i risultati.
   Se divergono, l'esercizio si butta. Costa il doppio ma solo sugli esercizi.
5. **Matematica: verificare fuori dal modello** quando si può: espressioni numeriche
   e simboliche passano da Wolfram (già integrato per la penna magica) come oracolo
   di verifica della risposta finale.
6. **Temperature basse e compiti piccoli**: un modulo per chiamata, un materiale per
   sezione; i compiti estrattivi (riassunto, flashcard) allucinano molto meno dei
   compiti generativi aperti.
7. **Provider secondo il vincolo di gratuità (§0)**: default consigliato Gemini
   free tier (alias `gemini-flash-latest`, chiave gratuita dell'utente,
   temperatura 0.2). **Usare sempre l'alias, mai una versione fissa**: Google
   ritira le versioni puntuali per i nuovi utenti (gemini-2.5-flash risponde
   404 "no longer available to new users") e l'app si romperebbe in silenzio
   per chi crea una chiave oggi. Niente `thinkingConfig`: i flash correnti lo
   rifiutano con 400. Claude solo BYOK;
   Claude solo BYOK per chi ce l'ha; Apple locale come fallback zero-config
   etichettato "on-device" (ok per flashcard/riassunti estrattivi, debole sugli
   esercizi). Il doppio passaggio del punto 4 consuma quota free tier: renderlo
   attivabile dall'utente (ed è il candidato naturale per un futuro premium).
8. **L'autovalutazione è l'ultima rete**: il player chiede comunque all'utente se la
   soluzione torna; un pulsante "Segnala errore" sui contenuti generati chiude il cerchio
   (e in futuro alimenta la rigenerazione).

## 4. WeBeep e temi d'esame

- **Autenticazione: già risolta correttamente.** Il flusso Moodle mobile
  (`WebeepAuthView` + `WebeepService`) fa fare il login sulla vera pagina Polimi
  (SSO + MFA inclusi) in un browser incorporato e riceve solo il token: l'app non
  vede mai la password. Non serve altro; NON fare scraping HTML della pagina di login.
- **Recupero materiali: REST Moodle, non scraping.** `core_course_get_contents` copre
  slide/dispense/temi d'esame pubblicati nel corso. Il "webscraping" vero serve solo
  se i temi d'esame stanno fuori da WeBeep; in quel caso meglio il caricamento manuale
  del PDF (già supportato) che un parser HTML fragile.
- **Classificazione temi d'esame**: euristica sul nome (`tema|esame|appello|prova|tde`)
  già attiva nel picker, correggibile a mano col toggle. Basta così per ora.
- **Rischi/limiti**: token che scade (gestito: errori espliciti e re-login);
  nomi multilang (gestito con `stripMultilang`); PDF scansionati senza testo →
  servirebbe OCR (Vision) come fallback nell'estrazione; rate: scaricare on-demand,
  non sincronizzare interi corsi. Sul piano regole: i materiali restano sul
  dispositivo dell'utente per uso personale di studio — stessa classe d'uso
  dell'app Moodle ufficiale; non ridistribuire contenuti.

## 5. Raccomandazioni sui punti aperti

- **MATLAB: no all'esecuzione embedded.** Non esiste un runtime MATLAB su iPad
  integrabile gratis; le alternative realistiche sono (a) link "Apri in MATLAB
  Mobile/Online" precompilando lo snippet negli esercizi pratici, (b) widget di
  calcolo già esistenti (Wolfram/GeoGebra) per la parte numerica. Rimandare
  qualunque cosa oltre questo: costo alto, valore incerto.
- **Ristrutturazione Ricerca**: rimandarla finché Studio non è consolidato; l'unica
  modifica a basso costo che vale subito è permettere "manda a Studio" dai risultati
  di ricerca (un articolo diventa materiale di uno studio).
- **Import note da altri**: la leva più concreta è l'export/import di una nota come
  pacchetto (`.boostnote` = zip con JSON del modello + PDF/media) condivisibile via
  AirDrop/file. PDF import esiste già; formati proprietari altrui (Notability,
  GoodNotes) non hanno formati aperti affidabili → non inseguirli.
- **Community/PoliNetwork**: non costruire una sezione Community in-app ora (moderazione,
  backend, massa critica). Scope minimo sensato: condivisione di *mazzi/studi* via
  file (stesso meccanismo dell'export note). Per la visibilità: contattare PoliNetwork
  (progetto studentesco, canali Telegram molto seguiti al Polimi) per una segnalazione
  dell'app; sul lato istituzionale il canale realistico è "Passion in Action" /
  i rappresentanti degli studenti, non i canali ufficiali dell'ateneo.
