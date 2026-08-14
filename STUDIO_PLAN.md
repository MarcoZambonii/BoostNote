# Piano di lavoro — Ambiente "Studio"

Stato (aggiornato 2026-08-14): la generazione AI reale è **attiva e completa**
per riassunti, flashcard, punti di ripasso ed esercizi, con la checklist
anti-allucinazione implementata (grounding, JSON validato, citazioni verificate,
correttore opzionale sugli esercizi). Il mock resta solo come rete di sicurezza
quando nessun provider è configurato. Questo documento tiene lo stato reale,
l'architettura e ciò che manca, in ordine di priorità.

## 0. Vincolo architetturale: gratuità a larga scala

L'app deve restare gratuita anche con molti utenti: **i costi variabili scalano
con l'utente, non con lo sviluppatore**. In pratica:

1. **Inferenza AI lato client** (`AIService.swift`): Gemini free tier come default
   consigliato (chiave gratuita che l'utente crea su aistudio.google.com), BYOK
   opzionale (Claude), modello Apple locale come fallback zero-config. Nessuna
   chiamata LLM centralizzata.
2. **WeBeep lato client**: le credenziali Polimi non transitano mai da un server
   proprio (già così: flusso Moodle mobile, token in Keychain).
3. **Local-first**: dati sul dispositivo (SwiftData); sync opzionale via Drive
   dell'utente; backend minimo (free tier Supabase/Cloudflare) solo per auth e
   feature community, quando/se serviranno.
4. **Premium aggiungibile senza ristrutturare** (es. correttore sempre attivo,
   generazioni batch), ma il core di studio resta gratuito.

## 1. Cosa esiste (agosto 2026)

| File | Ruolo |
| --- | --- |
| `BoostNote/StudioModels.swift` | SwiftData: `Study`, `StudyModule`, `StudyMaterial` (testo estratto persistito), `ExerciseAttempt` + payload Codable dei moduli |
| `BoostNote/StudioGenerationService.swift` | Pipeline di generazione reale: prompt, validazione, verifica citazioni, correttore esercizi |
| `BoostNote/AIService.swift` | Layer provider-agnostico: Gemini (catena di modelli), Claude BYOK, Apple on-device |
| `BoostNote/StudioEnvironmentView.swift` | Ambiente Studio; gli studi vivono nell'albero della barra laterale principale |
| `BoostNote/StudioCreateFlow.swift` | Crea studio: nome/materia → materiali (note, WeBeep, PDF, con download ed estrazione testo alla selezione) → moduli+opzioni |
| `BoostNote/StudyDetailView.swift` | Viewer moduli: Markdown+LaTeX (KaTeX), badge "Fonte verificata", player esercizi con autovalutazione |
| `BoostNote/ExerciseReportSheet.swift` | "Segnala errore" su un esercizio |
| `BoostNote/StudioProgressView.swift` | Analisi dei progressi (Swift Charts) da `ExerciseAttempt` |

### La pipeline di generazione, com'è davvero

- **Materiali con testo estratto on-device alla selezione** (`StudyMaterial.extractedText`):
  caselle di testo delle note, scrittura a mano via OCR, PDF via PDFKit. La
  generazione non rilegge le note al volo. Budget prompt: **100.000 caratteri**
  distribuiti tra i materiali, con troncamento dichiarato nel prompt e avviso
  visibile sulla card dello studio.
- **Catena di modelli Gemini** (quota per-modello, quindi le quote si sommano:
  ~1.060 richieste/giorno sul free tier): alias `-latest` in testa perché mai
  ritirati, versioni fisse dopo (un 404 fa proseguire la catena). Modelli
  separati per scopo; 429 disambiguato tra limite al minuto (attesa e retry
  stesso modello) e quota giornaliera (si scende nella catena). Gemma esclusa:
  non rispetta il JSON.
- **Un modulo per chiamata, moduli in parallelo** (TaskGroup), temperatura bassa.
- **JSON validato dal decoder**: risposta malformata → un secondo tentativo
  (i modelli sotto carico degradano più spesso di quanto falliscano); array
  nudi o con chiave sbagliata recuperati (`rewrapArray`); escape LaTeX
  protetti dalla decodifica JSON (`protectLaTeXEscapes` — la classe di bug
  della corruzione silenziosa: `\frac` letto come form feed + "rac").
- **Citazioni verificate davvero**: la citazione si cerca letteralmente nel
  materiale; seconda chance con normalizzazione (via marcatori Markdown/LaTeX
  e spazi) per il caso "il modello ha riscritto la notazione"; le parafrasi e
  le citazioni inventate NON passano. Il badge "Fonte verificata" compare solo
  su riscontro reale; `reverifyCitations` riallinea i contenuti già generati.
- **Regola del verbatim**: la formattazione (Markdown/LaTeX) si applica solo al
  testo del modello; il campo `quote` resta testuale identico alla fonte — è
  ciò che rende possibile la verifica letterale.
- **Correttore sugli esercizi** (opt-in, `options.verifyExercises`): seconda
  chiamata "da correttore severo" che risolve da zero e giudica la risposta
  proposta; consuma quota, quindi lo attiva l'utente.
- **Resa matematica**: KaTeX + marked in bundle; la matematica (inclusi gli
  ambienti nudi tipo `pmatrix`) viene schermata prima del parser Markdown,
  altrimenti `\\` e `_` vengono mangiati e una matrice 3×3 diventa un vettore
  riga senza alcun errore.
- **Ultima rete: l'utente.** Autovalutazione nel player e "Segnala errore" sui
  contenuti generati.

## 2. Cosa manca, in ordine di priorità

1. **Chunking dei materiali lunghi**: con un corso intero si tronca comunque a
   100k. Generare per blocchi e unire moltiplica le chiamate → va incrociata
   con le quote free tier; insieme, valutare un contatore di consumo nel Profilo.
2. **Citazioni puntuali (`sourceRange`)**: oggi la citazione porta il titolo del
   materiale e il testo verificato; manca il riferimento a pagina/posizione per
   aprire il passaggio originale accanto alla generazione.
3. **Spaced repetition sulle flashcard** (SM-2 semplificato): campi
   `easiness/interval/dueDate` nel payload + filtro "da ripassare oggi".
4. **Collegamento nota → studio**: dalla nota, saltare allo studio che la usa
   come materiale (ricerca per `noteID` nei materiali).
5. **Aggiunta moduli a uno studio esistente** ("Rigenera" c'è già).
6. **Estrazione con modello vision per le pagine con formule**: Vision on-device
   va bene sulla prosa ma sulla matematica è scarso (un integrale definito
   diventa "xdx"). Il modello vision è già integrato per la penna magica:
   passarci anche le pagine dense di formule. Costo: una pagina = una chiamata.
7. **Wolfram come oracolo** sulla risposta finale degli esercizi numerici/simbolici
   (già integrato per la penna magica): verifica fuori dal modello dove possibile.

## 3. Principi anti-allucinazione (implementati, da mantenere)

Il rischio vero per un'app di studio è generare cose *plausibili ma sbagliate*.
Le difese elencate in §1 discendono da questi principi, validi anche per i
moduli futuri:

1. **Grounding stretto**: nel prompt SOLO il testo dei materiali, con istruzione
   esplicita di non completare dalla conoscenza propria del modello.
2. **Ciò che non si può verificare non si mostra come verificato**: il badge
   segue il riscontro letterale, mai la fiducia nel modello.
3. **Output strutturato e validato**: ciò che non decodifica non si mostra.
4. **Compiti piccoli**: un modulo per chiamata; i compiti estrattivi allucinano
   meno dei generativi aperti.
5. **La verifica costosa è opt-in** (correttore): il free tier dell'utente è un
   budget, la sicurezza extra si sceglie.

## 4. WeBeep e temi d'esame

- **Autenticazione: risolta correttamente.** Flusso Moodle mobile
  (`WebeepAuthView` + `WebeepService`): login sulla vera pagina Polimi (SSO +
  MFA) in un browser incorporato, all'app arriva solo il token (Keychain).
  NON fare scraping HTML della pagina di login.
- **Recupero materiali: REST Moodle** (`core_course_get_contents`), struttura
  reale a sezioni/moduli. Il picker WeBeep è riusato anche per importare PDF
  come pagine nelle note (pannello Documenti e barra strumenti).
- **Classificazione temi d'esame**: euristica sul nome
  (`tema|esame|appello|prova|tde`) nel picker, correggibile col toggle.
- **Rischi/limiti**: token che scade (gestito: errori espliciti e re-login);
  nomi multilang (gestito con `stripMultilang`); PDF scansionati senza testo →
  OCR Vision come fallback nell'estrazione; scaricare on-demand, non
  sincronizzare interi corsi. Sul piano regole: i materiali restano sul
  dispositivo dell'utente per uso personale di studio — stessa classe d'uso
  dell'app Moodle ufficiale; non ridistribuire contenuti.

## 5. Raccomandazioni sui punti aperti

- **MATLAB: no all'esecuzione embedded.** Nessun runtime MATLAB gratis su iPad;
  le alternative realistiche sono (a) link "Apri in MATLAB Mobile/Online" con
  snippet precompilato negli esercizi pratici, (b) gli strumenti di calcolo già
  esistenti (Wolfram/Desmos) per la parte numerica.
- **Ristrutturazione Ricerca**: rimandata; l'unica modifica a basso costo che
  vale subito è "manda a Studio" dai risultati (un articolo diventa materiale).
- **Import note da altri**: la leva concreta è l'export/import come pacchetto
  (`.boostnote` = zip con JSON del modello + PDF/media) via AirDrop/file.
  Formati proprietari altrui (Notability, GoodNotes) non hanno formati aperti
  affidabili → non inseguirli.
- **Community/PoliNetwork**: niente sezione Community in-app ora (moderazione,
  backend, massa critica). Scope minimo: condivisione di mazzi/studi via file.
  Per la visibilità: PoliNetwork e "Passion in Action" / rappresentanti degli
  studenti, non i canali ufficiali dell'ateneo.
- **Informativa privacy in-app** prima di distribuire ad altri studenti: sul
  free tier Gemini i contenuti inviati possono essere usati per l'addestramento;
  va detto dentro l'app, non solo a voce.
