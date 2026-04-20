# MemoryMesh — Guida Installazione

> Guida end-user per deploy del server e pairing di un PC con Claude Code / Codex.
> Per la specifica tecnica: `ARCHITECTURE.md`, `PLUGIN.md`, `CODEX.md`, `UI_ADMIN.md`.

## Cosa ti serve

- Un home server Linux (mini PC, NAS, Raspberry Pi 5 con 16GB, VM) con Docker
- Una rete locale (LAN) raggiungibile da tutti i device dove usi Claude Code / Codex
- DNS locale o hostname `mm.local` risolvibile (via mDNS) oppure IP statico
- Browser moderno per la prima configurazione (admin UI)
- App TOTP (1Password, Authy, Google Authenticator, ecc.) sul tuo telefono

**Optional ma raccomandato**: una passkey/YubiKey per secondo fattore più forte del TOTP.

## Fase 1 — Deploy Server (5-10 minuti, una volta sola)

### 1a. Scegli il profilo deployment

Prima di `make up`, decidi come configurare LLM e embedding:

| Profile | Cloud data | RAM server | Adatto per |
|---------|-----------|-----------|------------|
| **A (default)** | Tutto via Gemini | ~2.75 GB | Single user, famiglia, budget cloud OK (<$3/mese) |
| **B** | LLM cloud, embed locale | ~3.65 GB | Bilanciato: embedding privati, LLM in cloud |
| **C** | Zero cloud | ~9.15 GB picco | Mini-PC 16GB, privacy stretta |

### 1b. Ottieni API key Gemini (solo Profile A o B)

1. Apri https://aistudio.google.com/apikey
2. Accedi con Google account
3. Click "Create API key" → copia la key (formato `AIza...`)
4. Free tier: 15 req/min, 1M token/giorno → più che sufficiente per home server

> **Privacy disclaimer** (Profile A o B): il contenuto delle tue observation
> viene inviato a Google per distillation/compression. Secret scrubbing
> automatico rimuove API key, JWT, credenziali detectate prima dell'invio.
> Google può conservare i prompt fino a 30 giorni per monitoring abuse.
> Vedi [Google AI API Terms](https://ai.google.dev/terms) per dettagli.
> Se non accettabile, usa Profile C (zero cloud).

### 1c. Clone e configurazione

```bash
git clone https://github.com/schengatto/memorymesh
cd memorymesh
cp .env.example .env
make secrets-gen >> .env        # genera SECRET_KEY + password DB/Redis

# Edita .env:
#   - MEMORYMESH_HOSTNAME (es. mm.local)
#   - ADMIN_EMAIL (per Let's Encrypt se profile vpn/public)
#   - MEMORYMESH_LLM_PROVIDER (gemini default, cambia solo se Profile C)
#   - GEMINI_API_KEY (da step 1b)
#   - MEMORYMESH_LLM_DAILY_TOKEN_CAP (500000 default ok)
$EDITOR .env
```

### 1d. Avvio stack

```bash
# Profile A (default, cloud):
make up

# Profile B o C (con Ollama locale):
docker compose --profile ollama up -d

# In entrambi i casi: attendi ~60s al primo avvio (pull immagini + init-db)
make health   # verifica che tutti i servizi siano up
```

Verifica:

```bash
curl http://mm.local/health
# → {"status":"ok","postgres":"up","redis":"up","ollama":"up",...}
```

Se `mm.local` non risolve (mDNS bloccato): usa l'IP diretto o configura
un alias nel tuo `/etc/hosts`.

### Fase 1b — Firewall

Il server espone solo due porte verso la LAN:
- `80` (Caddy) — reverse proxy per FastAPI e UI admin
- `5353/udp` (zeroconf mDNS) — solo se vuoi auto-discovery dei device

Le porte interne (PostgreSQL, Redis, Ollama) sono bindate solo su `127.0.0.1`
e network Docker. Non esposte alla LAN.

## Fase 2 — Bootstrap Admin (2 minuti, una volta sola)

Apri `http://mm.local/admin/` nel browser del tuo PC principale.

Al primo accesso vedi la pagina **Setup**:

1. Scegli un username
2. Imposta una password robusta (minimo 12 caratteri, zxcvbn score ≥ 3)
3. Viene mostrato un **QR code TOTP** + 10 **recovery codes**
   - Scansiona il QR con la tua app authenticator
   - Salva i recovery codes in un password manager (servono se perdi il device TOTP)
4. Digita il codice TOTP corrente a 6 cifre per verificare
5. Sei dentro. Fai il primo login con username + password + TOTP.

**Opzionale** (consigliato dopo il primo login): vai su **Account → Passkeys**
e registra una YubiKey o passkey biometrica per login più veloce nei giorni futuri.

## Fase 3 — Pair il Primo Device (30 secondi)

### 3a. Genera PIN dall'admin UI

`http://mm.local/admin/` → **Account → Devices → Pair new device**

1. (Opzionale) Label hint: "MacBook Enrico"
2. (Opzionale) Project default: se hai già creato progetti, seleziona
3. Click **Generate PIN**
4. Vedi un **PIN a 6 cifre** valido per 5 minuti (timer live in pagina)

### 3b. Installa il plugin Claude Code

Nel PC dove vuoi usare Claude Code (può essere lo stesso PC dove sta l'admin
UI, o un altro qualsiasi sulla LAN), apri Claude Code e digita:

```
/plugin marketplace add github:schengatto/memorymesh-marketplace
/plugin install memorymesh
```

Claude Code scarica il plugin. Al termine parte il **post-install script**:

```
🧠 MemoryMesh — zero-touch setup
🔎 Ricerca server MemoryMesh sulla LAN...
✓ Trovato: mm.local (http://mm.local)

Apri http://mm.local/admin/ → Account → Devices → Pair new device
PIN: _
```

Digita il PIN visto nell'admin UI (lo vedi già aperto dal punto 3a).

```
PIN: 123456
Nome device [default: enrico-mbp.local]:
Pair in corso... ✓
✓ Progetto auto-rilevato da git remote: my-app
✅ MemoryMesh configurato. Usa Claude Code normalmente.
```

**Fatto.** Apri una nuova sessione Claude Code: troverai vocab + contesto root
già iniettati, e puoi usare `/mm-search <query>`, `/mm-vocab`, `/mm-stats`.

### 3c. (Facoltativo) Aggiungi Codex allo stesso device

Se sullo stesso PC usi anche Codex:

```bash
npm install -g @memorymesh/cli
memorymesh install --for codex
# Skip pair — legge device.json già esistente
# Aggiunge solo MCP config Codex + shell wrapper 'cx'
```

Usa `cx <args>` invece di `codex <args>`. Claude Code e Codex condividono
la stessa memoria.

## Fase 4 — Verifica Funzionamento

### In Claude Code

1. Apri una sessione su un progetto che ha già qualche file:
   ```
   cd ~/code/my-app
   claude
   ```
2. Claude Code carica il prefisso cache-stable (vocab + obs root) all'avvio.
   Verifica scrivendo: `/mm-stats` → dovresti vedere counter token non-zero.
3. Fai un Edit su un file qualsiasi. Poi:
   ```
   /mm-search jwt auth
   ```
   Se hai già osservazioni rilevanti le vedrai. Se il progetto è nuovo, vuoto.
4. Aspetta la notte (o forza `/mm-distill` da admin UI Settings): al mattino
   troverai vocab auto-estratto + manifest rebuilt.

### Nell'admin UI

- **Dashboard**: `obs_count`, `vocab_terms` dovrebbero crescere ogni giorno d'uso
- **Account → Devices**: vedi il device appena paired, `last_seen_at` recente
- **Audit**: vedi entry `pair.consume` + ogni tua azione admin

## Troubleshooting

### `mm.local` non risolve

- **Linux**: installa `avahi-daemon` sia sul server che sul client
- **macOS**: funziona out-of-box via Bonjour
- **Windows**: installa Bonjour Print Services (gratuito di Apple)
- **Fallback**: usa l'IP del server (`192.168.1.x`) al posto di `mm.local`

### mDNS discovery non trova il server

- Molti router WiFi bloccano mDNS fra VLAN/guest network — connetti server e client
  alla stessa VLAN
- Verifica con `dns-sd -B _memorymesh._tcp` (macOS/Linux con avahi-utils)
- Fallback: nel post-install prompt "Enter server URL" digita manualmente

### Pair error "pin_expired_or_consumed"

- I PIN scadono dopo 5 minuti e sono one-shot
- Genera un nuovo PIN dall'admin UI

### Pair error "too_many_attempts"

- Oltre 10 PIN sbagliati dallo stesso IP in 15 minuti → bloccato
- Attendi 15 minuti, oppure admin può whitelisting dal pannello Settings

### Plugin non si connette — errore 401

- L'admin ha probabilmente revocato il device dall'admin UI
- Rerun `/mm-pair` nel plugin per ri-paire

### Claude Code non carica il plugin

- Verifica versione: `claude --version` deve supportare i plugin (v1.0+)
- Prova `/plugin list` per vedere se memorymesh è installato
- Check logs: `tail -f ~/.claude/plugins/memorymesh/install.log`

### Gemini API errori 429 (quota exceeded)

Free tier Google: 15 req/min per model, 1M token/giorno. Se superi:
- Verifica usage in `/admin/stats` → `llm_usage_today`
- Abbassa `MEMORYMESH_LLM_DAILY_TOKEN_CAP` in .env (evita spesa)
- Upgrade a tier pagato: <$1/mese per uso tipico
- O passa a Profile C: `MEMORYMESH_LLM_PROVIDER=ollama` + riavvio con `--profile ollama`

### Budget cap trigger (distillation saltata)

Audit log `/admin/audit` filtra per `action=llm_budget_exceeded` per vedere
quando è stato trippato. Se volontario: alza cap. Se involontario: investiga
se hai osservazioni malformate che causano loop.

### Voglio cambiare provider LLM dopo setup

```bash
# In .env
MEMORYMESH_LLM_PROVIDER=anthropic      # da gemini a claude
MEMORYMESH_LLM_MODEL=claude-haiku-4-5
ANTHROPIC_API_KEY=sk-ant-...

# Riavvio soft (no restart DB)
make restart-api
```

Nessuna migrazione DB: embedding già calcolati restano compatibili.
Solo il provider delle prossime chiamate LLM cambia.

### Tutto rotto, voglio ricominciare

```bash
# Lato plugin
rm -rf ~/.memorymesh
/plugin uninstall memorymesh

# Lato server (ATTENZIONE: cancella TUTTE le memorie)
make down && docker volume rm memorymesh_pg_data && make up
```

## Backup

```bash
make backup   # pg_dump in ./backups/YYYY-MM-DD.sql.gz
```

Include: observations, vocab_entries, device_keys, admin_users (password hash + TOTP cifrato).

**Importante**: il TOTP è cifrato con `SECRET_KEY`. Se ripristini il backup
su un server nuovo, DEVI riusare lo stesso `SECRET_KEY` oppure il TOTP
diventerà illeggibile (dovrai usare un recovery code e ri-enrollare).

## Update

```bash
cd memorymesh
git pull
make migrate   # migrazioni Alembic
make ui-build  # rebuild SPA
make build && make up  # rebuild immagini
```

Plugin Claude Code si aggiorna automaticamente via marketplace. Per forzare:

```
/plugin update memorymesh
```

Questo **non** richiede ri-paire: il `device.json` resta valido attraverso gli
update del plugin.
