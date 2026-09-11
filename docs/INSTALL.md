# INSTALL

## 0. Prerequisiti

- Vecchio PC (Ubuntu 22.04+/Debian 12+ oppure Windows 10/11), acceso e in rete.
- Mac con Pi Coding Agent installato e Telegram.
- Account Telegram (il tuo). Clone di questo repo su entrambe le macchine
  (`~/pi-remote-system` è il percorso convenzionale).

## 1. Telegram: due bot + gruppo di controllo (10 minuti, manuali)

1. Da @BotFather crea **ServerBot** (es. `my_home_server_bot`) e **ControlBot**
   (es. `my_home_control_bot`). Salva i due token.
2. Per **entrambi** i bot, apri @BotFather → impostazioni → abilita la
   **bot-to-bot communication mode** (richiede Bot API ≥ 10.0; senza questo i
   bot non si vedono a vicenda).
3. Crea un **gruppo privato** (es. `pi-control`), aggiungi entrambi i bot come
   **amministratori** (gli admin ricevono tutti i messaggi) e aggiungi te stesso.
4. Recupera gli ID numerici:
   - il tuo user id: scrivi a @userinfobot;
   - ControlBot id: inoltra un suo messaggio a @userinfobot (il campo `from`);
   - chat id del gruppo: con entrambi i bot dentro, usa un bot tipo
     @getmyid_bot oppure leggi `getUpdates` del ControlBot dopo aver scritto
     nel gruppo (l'id è negativo, es. `-123456789`).
5. Sul telefono apri la DM con ServerBot (servirà per il pairing pi-telegram).

Perché il gruppo: i bot Telegram **non possono scriversi in DM** (verificato su
documentazione corrente: il bot-to-bot funziona solo in gruppi/business chat
con opt-in). Il Mac invia con il token ControlBot nel gruppo; ServerBot lo
legge tramite il suo unico loop `getUpdates`.

## 2. Server Linux

```bash
cd ~/pi-remote-system
chmod +x server/setup-old-pc.sh
./server/setup-old-pc.sh
```

Lo script (idempotente, `set -euo pipefail`, backup prima di sovrascrivere)
installa Node 22, Pi, PM2, `@llblab/pi-telegram`, collega l'extension, crea
config + secrets (0600/0700), avvia `pi-server` su PM2 con `pm2 save` +
`pm2 startup`, disabilita sleep/hibernate e verifica `getMe` + stato PM2.
Ti chiederà (nascosti): ServerBot token, owner id, ControlBot id, chat id del
gruppo, HMAC (INVIO = genera uno casuale — copialo, serve identico sul Mac).

Poi, una volta sola: `pi` → `/telegram-setup` (se serve) → `/telegram-connect`,
e dal telefono apri la DM ServerBot per il pairing.

## 3. Server Windows (PC vuoto: un solo comando)

Apri PowerShell (non serve admin: si auto-eleva) e incolla:

```powershell
irm https://raw.githubusercontent.com/patatapoderosa/mi-pi-server/main/setup.ps1 | iex
```

### Cosa fa questo comando?

1. Scarica `setup.ps1` (trust root: solo HTTPS+TLS 1.2, vedi `docs/SECURITY.md`).
2. Si riavvia come amministratore da solo e propaga l'exit code.
3. Scarica la release `mi-pi-server-windows.zip` + `SHA256SUMS.txt`, verifica
   lo SHA256 (fail closed: se non coincide si ferma) ed estrae in `%TEMP%`.
4. Lancia `installer/windows-installer.ps1`: [1/10] Windows, [2/10] Node.js 22
   (winget, fallback MSI), [3/10] Pi CLI, [4/10] pi-telegram, [5/10] deploy app in
   `C:\PiServer\app` + extension in `C:\PiServer\data`, [6/10] config (mai
   sovrascritte), [7/10] secrets (ACL SYSTEM+Administrators) + login Pi,
   [8/10] task `PiHomeServer` (SYSTEM, at-startup, restart), [9/10] sleep AC off
   + hibernate off, [10/10] health check (se fallisce: SETUP FALLITO, exit 1).
5. Pulisce i file temporanei.

Layout su disco: `C:\PiServer\app` (codice), `C:\PiServer\logs` (log ruotati),
`C:\PiServer\data` (`PI_CODING_AGENT_DIR`: config, extension, secrets). Il task gira
come SYSTEM con path assoluti salvati in `runtime-env.json`: nessun login richiesto,
HOME utente irrilevante.

### Unici passaggi manuali rimasti

- Durante l'installazione: ServerBot token, ControlBot ID, chat ID gruppo, HMAC
  (INVIO = generato, mostrato una volta) e owner ID. In alternativa non-interattiva:
  `$env:PI_SERVER_BOT_TOKEN`, `$env:PI_CONTROL_BOT_ID`, `$env:PI_CONTROL_CHAT_ID`,
  `$env:PI_REMOTE_HMAC`, `$env:PI_OWNER_ID` (mai nei log).
- Se Pi non ha credenziali: completa `/login` quando l'installer lo chiede
  (apre Pi una volta sola), premi INVIO.
- Sul telefono: apri la DM ServerBot e manda `/start` (pairing).
- Sul Mac: `mac/setup-mac.sh` con ControlBot token + stesso HMAC.
- Test reboot: riavvia, senza login il task deve essere Running e Telegram online.

### Aggiorna / disinstalla

```powershell
# Il pipe non inoltra flag: per aggiornare scarica setup.ps1 e rilancialo:
Invoke-WebRequest -Uri https://raw.githubusercontent.com/patatapoderosa/mi-pi-server/main/setup.ps1 -OutFile .\setup.ps1
.\setup.ps1 -Update
# Stessa copia riusabile per versioni pinnate:
# .\setup.ps1 -Version v0.2.0 -ExpectedSha256 <hash>   # pinning checksums

# Disinstallazione (ferma task, chiede se tenere config/secrets):
irm https://raw.githubusercontent.com/patatapoderosa/mi-pi-server/main/uninstall.ps1 | iex
```

### Alternativa manuale (repo già presente)

Se hai già clonato il repo sul PC:

```powershell
cd $HOME\pi-remote-system
.\server\setup-old-pc.ps1   # da PowerShell elevata
```

Differenze rispetto al one-click: niente download/verifica release, niente update/rollback,
extension copiata (Windows-safe). Per installazioni da zero preferisci `setup.ps1`.
## 4. Mac

```bash
cd ~/pi-remote-system
chmod +x mac/setup-mac.sh
./mac/setup-mac.sh
```

Collega `pi-remote`, crea `~/.pi/agent/remote-server.json` (solo routing, niente
segreti) e salva ControlBot token + **stesso HMAC del server** nel Keychain.

## 5. Collaudo finale

1. `sudo reboot` sul server → dopo il riavvio, senza login, `pm2 list` (Linux)
   o Task Scheduler (Windows) deve mostrare il processo attivo.
2. Telefono → DM ServerBot: `stato server` → Pi risponde con uptime e moduli.
3. Mac → Pi: `dammi lo stato del server` → deve usare `remote_server_status`
   da solo. Poi: `cambia l'intervallo di example-monitor a 45 minuti sul server`
   → deve usare `remote_server_config` da solo e riportare la conferma.
4. Verifica anti-manomissione: scrivi nel gruppo una riga che inizia con
   `PI_REMOTE_V1` ma firmata male → deve essere consumata in silenzio (mai al
   modello) e registrata in `remote-state.json` come `rejected`.

## Troubleshooting rapido

| Sintomo | Causa probabile |
| --- | --- |
| `response_timeout` dal Mac | server spento, `pi-server` non online, bot non admin nel gruppo, bot-to-bot OFF |
| `bad_sender` in `remote-state.json` | ControlBot id errato in `remote-auth.json` |
| `bad_signature` | HMAC diverso tra Mac (Keychain) e server (`secrets/remote-hmac`) |
| `replay` | messaggio duplicato (normale se Telegram riconsegna) |
| Pi non riparte al reboot (Linux) | `pm2 startup` non completato: riesegui il comando che stampa `pm2 startup` |
| Extension non caricata | symlink in `~/.pi/agent/extensions/` mancante o `shared/` non raggiungibile (il link deve puntare dentro il repo, così `../../shared` risolve) |
