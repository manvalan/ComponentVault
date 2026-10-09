# Coda libreria KiCad — API per le app

Le app (macOS, iPad/iOS e il futuro client Android) **non scaricano mai
direttamente** da SnapEDA, Ultra Librarian o EasyEDA e **non conoscono le
credenziali dei fornitori**. Inviano una richiesta al server; il worker sul
Mac (`mikylab_kikad_library/scripts/fetch_worker.py`), l'unico con
`credentials.json`, la esegue e carica i file risultanti.

```
App ──API_KEY──► POST /fetch/jobs ──► coda (Postgres)
                                         ▲ │
Mac worker ──WORKER_API_KEY── claim ─────┘ ▼ fetch_components.py → libreria MIKILAB
                              upload zip/png, complete
App ──API_KEY──► GET /fetch/jobs/{id}, GET /fetch/jobs/{id}/files/{nome}
```

## Chiavi

| Chiave | Dove sta | Può |
|---|---|---|
| `API_KEY` | `.env` del server + configurazione dell'app | creare richieste, leggerne lo stato, scaricare zip/render |
| `WORKER_API_KEY` | `.env` del server + `credentials.json` sul Mac | prendere richieste, caricare file, chiuderle |
| password SnapEDA/UL | solo `credentials.json` sul Mac (git-ignored) | — non arrivano mai al server né alle app |

Le due chiavi devono essere diverse (il server rifiuta di partire altrimenti).
Generale con `openssl rand -hex 32`. Header: `X-API-Key: <chiave>` (oppure
`Authorization: Bearer <chiave>`). Solo HTTPS.

Su Android: tenere `API_KEY` in EncryptedSharedPreferences / Android
Keystore, mai nel codice o nelle risorse dell'APK. Su iOS vale lo stesso
con il Keychain.

## Endpoint per le app (`API_KEY`)

### `POST /fetch/jobs` → 201
```json
{
  "items": [
    {"mpn": "RK805-1", "lcsc": "C2934708", "ref": "U2", "funzione": "PMIC",
     "nome": null, "categoria": "power"}
  ],
  "update": false
}
```
- `items`: 1–100. `mpn` obbligatorio (≤128). `lcsc` = `C` + cifre.
  `nome` (opzionale) = `[A-Za-z0-9][A-Za-z0-9._+-]*`. `categoria` (opzionale):
  `analog audio display fpga_cpld interface logic mechanical memory
  microcontrollers other power rf`. Valori non validi → 422.
- `update: true` reimporta i componenti già in libreria.

Risposta: l'oggetto job (sotto), con `status: "queued"`.

### `GET /fetch/jobs/{id}` · `GET /fetch/jobs?limit=50`
```json
{
  "id": "8ec6e251-…", "status": "partial", "error": "non importati: NOPE-123",
  "createdAt": "…", "updatedAt": "…", "request": {…},
  "result": {
    "library_check": {"ok": true, "summary": ["Errors:   0", "Warnings: 0", "RESULT: OK (no errors)"]},
    "components": [
      {"name": "RK805-1", "mpn": "RK805-1", "refs": ["U2"], "category": "power",
       "status": "IMPORTED", "source": "easyeda", "detail": "",
       "model3d": [{"footprint": "footprints/power/RK805-1.pretty/….kicad_mod",
                    "status": "OK", "messages": ["model inside F.CrtYd (z 0.00..0.76 mm)"]}],
       "files": {"kicad": "RK805-1.zip", "render": "RK805-1.png"}}
    ]
  }
}
```
- `status` del job: `queued` → `running` → `done` | `partial` (alcuni
  componenti non importati) | `failed`. Interrogare ogni ~5 s finché non è
  finito.
- `status` del componente: `IMPORTED`, `PRESENT` (già in libreria),
  `SKIPPED`, `FAILED` (motivo in `detail`, es. parte senza footprint o pin
  senza pad).
- `model3d[].status`: `OK`, `WARN` (orientamento/posizione da verificare,
  dettagli in `messages`), `SKIP`. Il pin 1 va sempre controllato nel render.

### `GET /fetch/jobs/{id}/files/{nome}`
Scarica `files.kicad` (zip con `symbols/…`, `footprints/….pretty/…`,
`3dmodels/…`, percorsi relativi alla libreria MIKILAB) o `files.render`
(PNG). Solo `.zip`/`.png`; altri nomi → 400.

## Indice della libreria

### `GET /library/index` (`API_KEY`)
Indice di tutti i simboli della libreria MIKILAB, pubblicato dal worker
all'avvio e dopo ogni richiesta (prima di chiuderla), generato da
`mikylab_kikad_library/scripts/library_index.py`:
```json
{"format": 1, "library": "MIKILAB", "generatedAt": "2026-10-09T01:08:00+00:00", "count": 21702,
 "components": [
   {"name": "AXP2101", "lib": "MIKILAB_AXP2101", "category": "power",
    "footprint": "MIKILAB_AXP2101:QFN-40_…", "lcsc": "C3036461", "own": true, "model3d": true},
   {"name": "USBLC6-2SC6", "lib": "MIKILAB_Power_Protection", "category": "power",
    "footprint": "Package_TO_SOT_SMD:SOT-23-6"}
 ]}
```
~2,5 MB, ~150 KB compresso (gzip). Risponde con `ETag`: inviando
`If-None-Match` con l'ETag della copia locale si ottiene `304` se non è
cambiato. Le app tengono una copia locale per verificare le BOM offline.
Confronto consigliato: codice LCSC, poi MPN normalizzato (solo `a-z0-9`,
minuscolo) contro `name` e `mpn`; a parità vince la voce con `own: true`.

### `PUT /library/index` (`WORKER_API_KEY`)
Corpo: il JSON sopra (max `FETCH_MAX_UPLOAD_MB`).

## Endpoint del worker (`WORKER_API_KEY`)

| Metodo | Percorso | Note |
|---|---|---|
| POST | `/fetch/worker/claim` | prossimo job in coda (`running`), 204 se vuota; un job `running` da più di 2 h torna in coda |
| PUT | `/fetch/worker/jobs/{id}/files/{nome}` | corpo binario, max `FETCH_MAX_UPLOAD_MB` (60) |
| POST | `/fetch/worker/jobs/{id}/complete` | `{"status": "done"|"partial"|"failed", "result": {…}, "error": ""}` |

## Deploy

In `.env` aggiungere `WORKER_API_KEY=…` e ricostruire (`docker compose up -d
--build api`): la tabella `fetch_jobs` viene creata all'avvio; i file stanno
nel volume `cvault_fetch_files`.
