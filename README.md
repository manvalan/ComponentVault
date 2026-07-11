# ComponentVault

App macOS per gestire l'archivio personale di componenti elettronici, con schede complete arricchite da LCSC e architettura pronta per DigiKey, iPad e API su michelebigi.it.

## Funzionalità (v0.2)

- Import CSV + JSON LCSC con bootstrap automatico
- Schede componente complete (immagini, datasheet, parametri)
- **Gestione stock** con storico movimenti e soglia minima
- **Tag e note** personali per componente
- **Filtri avanzati** per categoria, footprint, brand, tag, scorte
- **Progetti BOM** con verifica disponibilità e riserva stock
- **Alert scorte** (esauriti / sotto soglia)
- **Import BOM CSV** in progetti (designator + LCSC + quantità)

## Requisiti

- macOS 14.0+
- Xcode 15+

## Avvio rapido

1. Apri il progetto in Xcode:

   ```bash
   open ~/Documents/Develop/ComponentVault/ComponentVault.xcodeproj
   ```

2. Build & Run (`⌘R`)

3. **All'avvio l'app crea automaticamente il database** importando da:
   ```
   /Users/michelebigi/LCSC/json_full_data/   ← schede complete LCSC (priorità)
   /Users/michelebigi/LCSC/bom_riepilogo.csv
   /Users/michelebigi/LCSC/Componenti Elettronici.csv
   ```

   Se la cartella `json_full_data` non esiste, generala con:

   ```bash
   python3 ~/Documents/Develop/ComponentVault/Tools/lcsc_enrich.py \
     --csv "/Users/michelebigi/LCSC/Componenti Elettronici.csv"
   ```

4. Dovresti vedere **63 componenti** con schede complete (immagini, datasheet, parametri)

## Arricchimento batch (Python)

Per pre-generare JSON e CSV offline (utile prima del deploy server):

```bash
pip3 install beautifulsoup4 requests
python3 ~/Documents/Develop/ComponentVault/Tools/lcsc_enrich.py \
  --csv "/Users/michelebigi/LCSC/Componenti Elettronici.csv"
```

Output:
- `/Users/michelebigi/LCSC/json_full_data/{LCSC}.json`
- `/Users/michelebigi/LCSC/bom_riepilogo.csv`

## Architettura

```
ComponentVault/
├── Models/
│   ├── Component.swift          # SwiftData (persistenza locale)
│   ├── ComponentRecord.swift    # DTO condiviso (app ↔ API ↔ script Python)
│   └── ComponentParameter.swift
├── Services/
│   ├── ComponentDataProvider.swift  # Protocollo provider
│   ├── LCSCProvider.swift           # Fetch live da lcsc.com
│   ├── LCSCParser.swift             # Parser HTML (JSON-LD + __NEXT_DATA__)
│   ├── CSVImporter.swift
│   └── ComponentStore.swift
└── Views/
    ├── ContentView.swift            # Lista + ricerca
    ├── ComponentDetailView.swift    # Scheda completa
    └── SettingsView.swift
```

### Schema `ComponentRecord` (JSON)

```json
{
  "lcscCode": "C12345",
  "mpn": "STM32F407VGT6",
  "name": "ST STM32F407VGT6",
  "description": "...",
  "footprint": "LQFP-100(14x14)",
  "quantity": 2,
  "category": "Embedded Processors & Controllers/Microcontrollers",
  "value": "168MHz",
  "brand": "ST",
  "datasheetURL": "https://datasheet.lcsc.com/...",
  "imageURLs": ["https://assets.lcsc.com/..."],
  "price": 5.357,
  "currency": "USD",
  "supplierStock": 67,
  "dataSource": "lcsc",
  "parameters": { "Package": "LQFP-100(14x14)", "CPU Core": "ARM Cortex-M4" }
}
```

## Roadmap

| Fase | Obiettivo |
|------|-----------|
| **v0.1** | App macOS, import CSV, LCSC live |
| **v0.2** | Stock, progetti BOM, filtri, export, alert ✓ |
| **v0.3** | API REST su michelebigi.it + sync |
| **v0.4** | DigiKey provider (OAuth2) |
| **v1.0** | App iPad (SwiftUI condiviso) |

## Note LCSC

I dati sono estratti da due blocchi HTML:
- `<script type="application/ld+json">` → MPN, parametri, immagini, datasheet, prezzo
- `<script id="__NEXT_DATA__">` → footprint (`webData.encapStandard`), catalogo

Il parser Swift replica la logica già validata nei tuoi script Python in `/Users/michelebigi/LCSC/`.
