# ComponentVault

App per iPad e Mac per l'archivio personale di componenti elettronici:
- schede dall'archivio LCSC locale e prezzi e disponibilità da Mouser e DigiKey (API ufficiali, con le tue chiavi);
- magazzino con dispensari e cassetti;
- progetti BOM;
- carico da etichetta con la fotocamera;
- integrazione con la tua libreria KiCad.

Nessun server e nessun account. Ogni dispositivo ha il proprio database locale (SwiftData/SQLite); i dispositivi condividono **una sola cartella**, a scelta (ad esempio in iCloud Drive).

## Funzionalità (v1.0)

- **Inventario** con stock, storico movimenti, soglie, tag e note
- **Posizione in magazzino**: dispensario e numero del cassetto, entrambi ricercabili
- **Carico da etichetta**: fotocamera (iPad) oppure lettore USB o codice digitato (Mac). Riconosce:
  - il QR delle buste LCSC/JLCPCB (`{pc:C25804,pm:…,qty:100}`);
  - il DataMatrix delle etichette dei distributori (ANSI MH10.8.2: `1P` MPN, `Q` quantità, `1V` produttore);
  - i codici LCSC `Cxxxxx`.
- **Progetti BOM** a checklist (magazzino, KiCad, prezzi LCSC), con import BOM EasyEDA/JLC
- **Libreria KiCad**: verifica la BOM sulla tua libreria e chiede i componenti mancanti al Mac che ha KiCad
- **Ricerca** nell'archivio locale e, con le tue chiavi, su Mouser e DigiKey; la sezione "Prezzi e disponibilità" nella scheda interroga i distributori configurati
- **Solo fonti autorizzate**: nessuno scraping di siti; chiavi e token nel Portachiavi del dispositivo
- **Italiano e inglese** (String Catalog `Localizable.xcstrings`); le altre lingue usano l'inglese

## Requisiti

- iPadOS 17 / macOS 14 o successivi
- Xcode 16 o successivo

## La cartella

In Impostazioni → **Cartella** scegli la stessa cartella su tutti i dispositivi. Senza cartella tutto resta sul dispositivo. L'app ricorda la cartella con un bookmark, quindi funziona anche nella sandbox dell'App Store.

```
<cartella>/componentvault_config.yml      configurazione, compreso il percorso della libreria KiCad
<cartella>/sync/components.json           inventario da scambiare
<cartella>/sync/projects.json             progetti
<cartella>/kicad/jobs/<uuid>/request.json richiesta di componenti KiCad (scritta dall'app)
<cartella>/kicad/jobs/<uuid>/status.json  esito (scritto dal worker sul Mac)
<cartella>/kicad/jobs/<uuid>/*.zip|*.png  file KiCad e render 3D
<cartella>/kicad/library_index.json       indice della libreria KiCad
<cartella>/kicad/worker.json              "Mac con KiCad attivo"
<cartella>/json_full_data/, *.csv         archivio LCSC per il primo avvio (opzionale)
```

- **Configurazione**: un solo file nella cartella, uguale per tutti i dispositivi. Ogni modifica nelle Impostazioni si salva da sola.
- **Libreria KiCad**: il percorso si imposta **dal Mac** (Impostazioni → KiCad → Libreria); l'iPad lo legge dal file di configurazione.
- **Scambio dati**: "Sincronizza ora", all'avvio o a intervalli. Inventario e progetti si fondono e vince la modifica più recente.
- **Worker KiCad**: sul Mac che ha la libreria, `scripts/fetch_worker.py` legge le richieste dalla stessa cartella:

  ```bash
  # credentials.json della libreria: "componentvault": {"shared_dir": "~/Library/Mobile Documents/com~apple~CloudDocs/ComponentVault"}
  python3 ~/Development/mikylab_kikad_library/scripts/fetch_worker.py
  ```

  Le credenziali SnapEDA e UltraLibrarian restano nel `credentials.json` del Mac e non entrano mai nella cartella.

## Avvio rapido

```bash
open ComponentVault.xcodeproj   # Build & Run (⌘R)
```

Al primo avvio l'app procede così:
1. Se la cartella contiene già `sync/components.json`, importa l'inventario degli altri dispositivi.
2. Altrimenti crea il database da `json_full_data/`, `bom_riepilogo.csv` o `Componenti Elettronici.csv` nella cartella dati.
3. In alternativa puoi importare un CSV dal menu.

Per generare l'archivio LCSC offline:

```bash
pip3 install beautifulsoup4 requests
python3 Tools/lcsc_enrich.py --csv "<cartella>/Componenti Elettronici.csv"
```

## Architettura

```
ComponentVault/
├── App/            avvio, percorsi (AppPaths: locale / cartella)
├── Models/         SwiftData (Component, Project, StockMovement…) e DTO (ComponentRecord)
├── Services/
│   ├── SharedFolder.swift      bookmark della cartella, file coordinati (iCloud)
│   ├── AppConfig.swift         configurazione YAML (nella cartella)
│   ├── FolderSync.swift        scambio di inventario e progetti tramite la cartella
│   ├── KiCadQueue.swift        richieste al worker KiCad sul Mac (file)
│   ├── KiCadLibraryIndex.swift indice della libreria KiCad, verifica della BOM offline
│   ├── LabelParser.swift       etichette LCSC e dei distributori
│   ├── ComponentStore.swift    inventario, carico, arricchimento LCSC
│   └── LCSC*, EasyEDA*         fornitori
├── Views/          SwiftUI (iPad + Mac)
├── Localizable.xcstrings      italiano (sorgente) e inglese
└── PrivacyInfo.xcprivacy      manifest privacy App Store
Web/                pagine statiche: privacy, supporto
AppStore/           testi e checklist per la pubblicazione
```

## Codici inventario e LCSC

| Codice | Uso |
|--------|-----|
| **CV-*** | Codice inventario ComponentVault (chiave univoca) |
| **Cxxxxx** (LCSC) | Codice fornitore LCSC, mostrato accanto al CV e usato in EasyEDA |

## Pubblicazione

Vedi [`AppStore/README.md`](AppStore/README.md): testi in italiano e inglese, privacy, note per la revisione e checklist.
