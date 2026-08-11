# Studio App — Starter (Passo 1: Note a cartelle)

## Come aprirlo in Xcode

1. Apri Xcode → **File > New > Project**
2. Scegli **iOS > App**, nome a piacere (es. "StudioApp")
3. Interface: **SwiftUI** — Storage: **SwiftData** (Xcode genera già alcuni
   file di esempio: cancella `Item.swift` e il `ContentView.swift`
   generato di default)
4. Trascina dentro al progetto Xcode questi 5 file, sostituendo quelli
   di default:
   - `Models.swift`
   - `StudioApp.swift` (sostituisce il file `<NomeProgetto>App.swift`
     generato da Xcode — rinominalo o rinomina la struct `@main` a
     seconda di cosa preferisci)
   - `RootView.swift`
   - `FolderView.swift`
   - `NoteEditorView.swift`

## Abilitare il sync CloudKit (gratuito)

1. Seleziona il progetto → target → tab **Signing & Capabilities**
2. **+ Capability** → **iCloud** → spunta **CloudKit**
3. Serve un Apple ID collegato a Xcode (Settings > Accounts) — quello
   gratuito basta per compilare e testare sul tuo iPad via cavo/wifi,
   nessun costo, nessun account developer a pagamento necessario per
   uso personale

## Cosa fa questa prima versione

- Creare cartelle e sottocartelle
- Creare note dentro una cartella, con titolo e testo
- Editing base del testo
- Sync automatico tra i tuoi dispositivi Apple via iCloud (una volta
  abilitata la capability sopra)

## Prossimo passo (step 2 della roadmap)

Aggiungere in `NoteEditorView.swift` un menu contestuale sulla
selezione del testo con due azioni — "Spiega" e "Genera flashcard" —
che chiamano l'API Anthropic. Fammi sapere quando hai questa versione
che gira sul tuo iPad e procediamo con quello.
