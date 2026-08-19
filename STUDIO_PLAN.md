# Piano di lavoro — Ambiente "Studio"

Stato (aggiornato 2026-08-19): la generazione AI reale è **attiva e completa**
per riassunti, flashcard, punti di ripasso ed esercizi, con la checklist
anti-allucinazione implementata (grounding, JSON validato, citazioni verificate,
correttore opzionale sugli esercizi). Il mock resta solo come rete di sicurezza
quando nessun provider è configurato. Questo documento tiene lo stato reale,
l'architettura e ciò che manca, in ordine di priorità.

Tre cose sono cambiate dalla stesura precedente e attraversano tutto il resto
del documento:

1. **Il Vault**: il materiale non viene più riletto e troncato a ogni
   generazione. Una cartella Studio è un corso, il suo materiale si legge UNA
   volta pagina per pagina, e un indice a chunk decide quali parti mandare al
   modello. Il troncamento cieco ai primi 100k caratteri non c'è più.
2. **Gli argomenti hanno una chiave canonica** (`TopicVocabulary.swift`): le
   varianti della stessa etichetta smettono di frantumare la griglia di
   creazione, il filtro dei chunk e le statistiche dei progressi.
3. **Le figure degli esercizi si compilano davvero** (TikZJax in WebAssembly,
   offline): la compilazione è il quality gate, e la decisione "qui serve una
   figura" è un campo obbligatorio dello schema, non un consiglio nel prompt.

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
| `BoostNote/VaultModels.swift` | Il vault di corso: `VaultDocument` (nota come riferimento vivo, o PDF), `VaultPage` con hash e lettore usato, `VaultChunk` con etichette |
| `BoostNote/VaultIngestionService.swift` | La coda di lettura: ripartibile (ogni pagina persistita col suo hash), incrementale (si rilegge solo ciò che è cambiato), parte da sola |
| `BoostNote/VaultIndexService.swift` | L'indice: chunk da ~25k caratteri su confini di pagina, etichettati con una chiamata Lite l'uno |
| `BoostNote/TopicVocabulary.swift` | Chiave canonica di un argomento: varianti morfologiche e acronimi, deterministico e offline |
| `BoostNote/TikZCompiler.swift`, `TikZFigureView.swift` | Compilazione TikZ → SVG con TikZJax (TeX in WebAssembly, nel bundle): offline e gratis, come KaTeX |
| `BoostNote/StudioEnvironmentView.swift` | Ambiente Studio; gli studi vivono nell'albero della barra laterale principale |
| `BoostNote/StudioCreateFlow.swift` | Crea studio: nome/materia → materiali (note, WeBeep, PDF, con download ed estrazione testo alla selezione) → moduli+opzioni |
| `BoostNote/StudyDetailView.swift` | Viewer moduli: Markdown+LaTeX (KaTeX), badge "Fonte verificata", player esercizi con autovalutazione |
| `BoostNote/ExerciseReportSheet.swift` | "Segnala errore" su un esercizio |
| `BoostNote/StudioProgressView.swift` | Analisi dei progressi (Swift Charts) da `ExerciseAttempt` |

### La pipeline di generazione, com'è davvero

- **Il Vault al posto della rilettura**: il materiale di una cartella Studio si
  legge una volta sola, pagina per pagina, e resta. Le note sono riferimenti
  vivi (`noteID`, mai copie): al sync si confrontano gli hash **per contenuto**,
  quindi inserire una pagina in mezzo costa una lettura e non quaranta. Il
  lettore usato resta scritto sulla pagina (`VaultPageReader`: livello di testo
  del PDF, Vision on-device, modello vision per la scrittura a mano) — serve
  all'onestà in UI e a decidere se rileggere quando arriva un lettore migliore.
  La coda riparte da dove era: chiudere l'app non butta lavoro.
- **L'indice sceglie, non si tronca**: ogni documento è spezzato in chunk da
  ~25k caratteri su confini di pagina, ognuno etichettato da una chiamata Lite
  con gli argomenti che copre e la sua natura (teoria / esercizi / misto).
  L'indice intero sta sempre in un prompt, ed è lui a decidere QUALI chunk
  entrano nella generazione dentro il budget di 100k caratteri: prima quelli che
  portano argomenti non ancora coperti, poi il resto. Quando il materiale non ci
  sta tutto, la nota sulla card dice quante parti sono entrate e quali argomenti
  sono rimasti fuori — un limite dichiarato, non subìto. Costo dell'indice: una
  dispensa da 167 pagine ≈ 16-20 chiamate Lite **una volta sola**, e le
  etichette si riusano per impronta (cambiare una pagina rietichetta il suo
  chunk, non il documento).
- **Un vocabolario solo per gli argomenti**: l'etichettatura di un chunk riceve
  in prompt le etichette già in uso nel Vault, con l'istruzione di copiarle alla
  lettera se l'argomento è lo stesso — e il prompt è una preghiera, quindi
  `TopicVocabulary` riporta comunque le varianti (accenti, plurali, sigle) alla
  forma canonica. Lo stesso vale a valle: gli argomenti degli esercizi vengono
  agganciati al vocabolario scelto in creazione (`snap`, anche sui sostitutivi
  rigenerati) e le statistiche dei progressi raggruppano sulla chiave, non sulla
  stringa nuda. La sinonimia vera ("dualità in PL" ≡ "problema duale") NON si
  risolve manipolando stringhe ed è volutamente fuori: semmai una chiamata Lite
  sulla LISTA di etichette, che non scala col materiale.
- **Catena di modelli Gemini** (quota per-modello, quindi le quote si sommano:
  ~1.060 richieste/giorno sul free tier): alias `-latest` in testa perché mai
  ritirati, versioni fisse dopo (un 404 fa proseguire la catena). Modelli
  separati per scopo; 429 disambiguato tra limite al minuto (attesa e retry
  stesso modello) e quota giornaliera (si scende nella catena). Gemma esclusa:
  non rispetta il JSON. Sugli esercizi la catena è in modalità "qualità prima"
  (`qualityFirst`): tutti i Flash capaci vengono provati prima di scendere sui
  Lite, perché lì la differenza di qualità si vede. Claude BYOK usa l'output
  strutturato del provider, non il JSON chiesto a parole.
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
- **Figure degli esercizi, compilate offline**: TikZJax (il TeX vero in
  WebAssembly) è nel bundle come KaTeX, quindi le figure non costano né rete né
  chiamate. Tre decisioni che valgono più del disegno in sé:
  - **la compilazione è il quality gate**: se il TeX del modello non compila la
    figura semplicemente non esiste — mai un disegno rotto sullo schermo, stesso
    principio del "ciò che non decodifica non si mostra";
  - **fallimento del contenuto ≠ motore non disponibile**: un TeX che non
    compila è definitivo e si ricorda; una webview che non parte è un fatto
    nostro e non deve condannare per sempre una figura sana (watchdog, morte del
    processo web e coda gestiti esplicitamente);
  - **la decisione è obbligatoria, il disegno no**: `figuraServe` è un campo
    REQUIRED dello schema, quindi il modello è costretto a porsi la domanda. Se
    dichiara true e poi non disegna, o se la traccia ha la forma di un elenco di
    relazioni, l'esercizio viene marcato `figureExpected` e il viewer lo dice
    ("servirebbe una figura, disegnala tu"): un'assenza dichiarata invece che
    silenziosa. Il rilevatore è strutturale, non lessicale — un elenco di parole
    chiave coprirebbe solo le materie a cui abbiamo pensato noi.
- **Resa matematica**: KaTeX + marked in bundle; la matematica (inclusi gli
  ambienti nudi tipo `pmatrix`) viene schermata prima del parser Markdown,
  altrimenti `\\` e `_` vengono mangiati e una matrice 3×3 diventa un vettore
  riga senza alcun errore.
- **Ultima rete: l'utente.** Autovalutazione nel player e "Segnala errore" sui
  contenuti generati.

## 2. Cosa manca, in ordine di priorità

1. **Citazioni puntuali (`sourceRange`)**: oggi la citazione porta il titolo del
   materiale e il testo verificato; ora che le pagine del Vault sono persistite
   con il loro indice, il riferimento a pagina è finalmente a portata — manca
   l'aggancio per aprire il passaggio originale accanto alla generazione.
2. **Generazione mirata delle figure mancanti**: `figureExpected` segna già dove
   una figura ci voleva e non c'è. Il passo naturale è una seconda chiamata
   sulla sola traccia, che produce il solo TikZ — al momento la mancanza si
   dichiara e basta.
3. **Spaced repetition sulle flashcard** (SM-2 semplificato): campi
   `easiness/interval/dueDate` nel payload + filtro "da ripassare oggi".
4. **Sinonimia degli argomenti**: la parte deterministica è fatta
   (`TopicVocabulary`), quella di dominio no. Una chiamata Lite sulla LISTA di
   etichette del Vault, non sui documenti: costo costante, non scala col
   materiale.
5. **Collegamento nota → studio**: dalla nota, saltare allo studio che la usa
   come materiale (ricerca per `noteID` nei documenti del Vault).
6. **Aggiunta moduli a uno studio esistente** ("Rigenera" c'è già).
7. **Wolfram come oracolo** sulla risposta finale degli esercizi numerici/simbolici
   (già integrato per la penna magica): verifica fuori dal modello dove possibile.
8. **Contatore di consumo nel Profilo**: con l'indice del Vault le chiamate sono
   diventate più prevedibili ma anche più numerose all'ingresso di un corso;
   l'utente dovrebbe poter vedere quanta quota gli resta.

Fatti da quando questa lista è stata scritta: il **chunking dei materiali
lunghi** (era il punto 1 — risolto dal Vault e dalla selezione per indice,
non più dal troncamento) e l'**estrazione con modello vision per le pagine
scritte a mano** (era il punto 6 — è il lettore `.model` di `VaultPage`,
scelto automaticamente quando c'è un provider configurato).

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
6. **Ciò che si può compilare o calcolare non si giudica**: un modello non viene
   messo a valutare il lavoro di un altro modello quando esiste un controllo
   programmatico. Il TikZ si compila (o la figura non esiste), la citazione si
   cerca nel testo, la figura mancante la rileva la contraddizione dichiarata
   dal modello stesso o la forma della traccia.
7. **Quello che si perde per strada va detto**: materiale che non entra nel
   budget, argomenti rimasti fuori dalla selezione, figura che ci voleva e non
   c'è. Un limite dichiarato lascia allo studente la possibilità di rimediare;
   un limite silenzioso gli fa credere di avere in mano tutto.

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
- **Import note da altri: fatto.** Il pacchetto `.boostnote` esiste
  (`NoteArchiveService`): un file per nota con l'inchiostro vero dentro,
  dichiarato in Info.plist quindi apribile con un tocco da File, e riimportabile
  come nota modificabile identica. Nasce come archivio automatico su una
  cartella dell'utente (pensata per OneDrive — 1TB gratuito con l'account
  Polimi), ma è la stessa strada per lo scambio via AirDrop. Formati proprietari
  altrui (Notability, GoodNotes) restano fuori: non hanno formati aperti
  affidabili → non inseguirli.
- **Community/PoliNetwork**: niente sezione Community in-app ora (moderazione,
  backend, massa critica). Scope minimo: condivisione di mazzi/studi via file.
  Per la visibilità: PoliNetwork e "Passion in Action" / rappresentanti degli
  studenti, non i canali ufficiali dell'ateneo.
- **Informativa privacy in-app** prima di distribuire ad altri studenti: sul
  free tier Gemini i contenuti inviati possono essere usati per l'addestramento;
  va detto dentro l'app, non solo a voce.
