# Deploy ComponentVault su VPS IONOS

Guida per il tuo server:
- **IP:** `82.165.138.64`
- **OS:** AlmaLinux 9 + Plesk
- **RAM:** 4 GB (sufficiente per PostgreSQL + API + rete neurale esistente)

> **Sicurezza:** non condividere la password `root` in chat. Dopo il primo accesso, crea un utente dedicato e disabilita login root via password se possibile.

---

## Cosa installiamo

```
Docker
  ├── PostgreSQL 16  (database componentvault)
  └── FastAPI        (porta locale 8100)
         ↑
Plesk / Nginx  →  https://api.michelebigi.it
```

L'API resta in ascolto solo su `127.0.0.1:8100` — non esposta direttamente su Internet.

---

## Passo 1 — Collegati al VPS

Dal Mac:

```bash
ssh root@82.165.138.64
```

---

## Passo 2 — Installa Docker (AlmaLinux 9)

```bash
dnf install -y dnf-plugins-core
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
docker --version
```

---

## Passo 3 — Carica i file sul server

**Dal Mac** (nuovo terminale):

```bash
cd ~/Documents/Develop/ComponentVault
scp -r Server root@82.165.138.64:/opt/componentvault
```

---

## Passo 4 — Configura `.env`

**Sul VPS:**

```bash
cd /opt/componentvault/Server
cp .env.example .env
nano .env
```

Genera password sicure:

```bash
openssl rand -hex 24   # per POSTGRES_PASSWORD
openssl rand -hex 32   # per API_KEY
```

Esempio `.env`:

```env
POSTGRES_DB=componentvault
POSTGRES_USER=cvault
POSTGRES_PASSWORD=<password_generata>
API_PORT=8100
API_KEY=<api_key_generata>
DATABASE_URL=postgresql+psycopg://cvault:<password_generata>@db:5432/componentvault
CORS_ORIGINS=https://michelebigi.it
```

---

## Passo 5 — Avvia database + API

```bash
cd /opt/componentvault/Server
docker compose up -d --build
docker compose ps
curl -s http://127.0.0.1:8100/health
```

Risposta attesa: `{"status":"ok","components":0}`

---

## Passo 6 — Sottodominio in Plesk

1. Plesk → **Domini** → `michelebigi.it`
2. **Sottodomini** → Aggiungi `api`
3. **Apache & nginx Settings** → regola nginx custom:

```nginx
location / {
    proxy_pass http://127.0.0.1:8100;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

4. **SSL/TLS** → Let's Encrypt per `api.michelebigi.it`

Test:

```bash
curl -s https://api.michelebigi.it/health
```

---

## Passo 7 — Carica inventario dal Mac

```bash
pip3 install requests
python3 ~/Documents/Develop/ComponentVault/Server/scripts/push_inventory.py \
  --api https://api.michelebigi.it \
  --key <TUA_API_KEY> \
  --dir /Users/michelebigi/LCSC/json_full_data
```

---

## Endpoint API

| Metodo | URL | Auth |
|--------|-----|------|
| GET | `/health` | no |
| GET | `/components` | `X-API-Key` |
| GET | `/components/{lcsc}` | `X-API-Key` |
| PUT | `/components/{lcsc}` | `X-API-Key` |
| POST | `/sync/push` | `X-API-Key` |

---

## Convivenza con la rete neurale

| Servizio | Porta |
|----------|-------|
| Rete neurale | 8000 (o altra) |
| ComponentVault | **8100** |

RAM stimata ComponentVault: ~200–400 MB su 4 GB totali.
