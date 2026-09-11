# SECURITY

## Threat model

Difendiamo da: messaggi Telegram contraffatti nel gruppo di controllo,
replay di messaggi legittimi, errori del modello (campi inventati), file di
config corrotti, furto del telefono/macchina, crash di rete/processo.

Non difendiamo da: PIN Telegram compromesso + accesso fisico a entrambe le
macchine + Keychain sbloccato (a quel punto l'attaccante è già l'utente).

## Protocol checks (server, in ordine)

Ogni messaggio con prefisso `PI_REMOTE_V1` viene **consumato** in ogni caso
(mai al modello). Prima di eseguire:

1. `from.id === allowedControlBotId` (silenzioso verso estranei: nessuna conferma).
2. (se configurato) `chat.id === controlChatId`.
3. HMAC-SHA256 su canonical-JSON (chiavi ordinate) con `crypto.timingSafeEqual`.
4. `|now - ts| ≤ maxSkewSeconds` (default 300, clamp 30–3600).
5. Nonce persistito (`remote-state.json`, finestra 2×skew, prune, max 500):
   duplicato → `replay`, anche dopo restart.
6. `op ∈ {set_config, get_status, ping, service}`.
7. `module` registrato (`core`, `example-monitor`, …) e master switch
   `core.remoteControlEnabled` / `maintenanceMode` rispettati.
8. `patch`: oggetto ≤25 chiavi, solo campi dichiarati nello schema del modulo,
   tipo/range/enum validati; merge su defaults + valori correnti noti.
9. `service ∈ allowedServices` (solo nomi, mai comandi) per `service/*`.
10. Scritture atomiche (tmp+rename) + backup timestampato prima di sovrascrivere.

Le risposte `PI_REMOTE_RESP_V1` sono firmate con lo stesso HMAC e correlate
via `requestId`; il Mac le verifica prima di mostrarle.

## Secrets & permissions

- Server: `secrets/` 0700, file 0600. Token/HMAC mai nei log (il codice non ha
  alcuna istruzione di log che li includa; gli errori HTTP Telegram riportano
  solo status/description).
- Mac: token ControlBot + HMAC solo nel Keychain (`security`
  `find-generic-password`); `remote-server.json` contiene solo routing.
- `telegram.json` contiene il token ServerBot: va bene (0600), ma a runtime
  vince `secrets/server-bot-token` quando presente.

## Cosa NON esiste (di proposito)

- Nessun tool `run_command`/`exec`/`terminal`, locale o remoto.
- Nessun campo `filePath`/`shellCommand`/`processName`/`command`/`script` in
  alcun messaggio: il validatore rifiuta ogni chiave non in schema.
- Nessuna porta aperta, nessun webhook, nessuna VPS: tutto esce in HTTPS verso
  `api.telegram.org`; niente accetta connessioni in ingresso.
- Nessun secondo loop `getUpdates` sul ServerBot (conflitto 409 garantito da
  Telegram se due poller insistono sullo stesso bot). Il Mac fa short-polling
  solo sul ControlBot, con tool in `sequential` per non sovrapporsi.


## Supply chain (installer Windows)

- Trust root onesta: `setup.ps1` viene scaricato via HTTPS da
  `raw.githubusercontent.com` e NON è verificato da checksum (niente verifica
  il verificatore). Tutto ciò che esegue dopo — `mi-pi-server-windows.zip` —
  è verificato SHA256 contro `SHA256SUMS.txt` della release (o `-ExpectedSha256`)
  con fail closed: hash diverso o assente = stop, niente esecuzione.
- Il checksum protegge da corruzione/manomissione del file in transito e da asset
  sbagliati, NON è una firma: chi controlla il repo GitHub o il TLS può comunque
  fornire un payload malevolo. Per installazioni sensibili: scarica un `setup.ps1`
  taggato, leggilo, e pinna `-ExpectedSha256`.
- L'installer valida anche il manifest (file attesi presenti) dopo l'estrazione.
- Nessuna regola firewall inbound, nessun port forwarding: il transport resta Telegram.
- `installer.log` non contiene mai secret (token/HMAC solo in file ACL o mostrati una
  volta a schermo con transcript sospeso).
## Residui noti / hardening futuro

- Il gruppo di controllo è visibile ai suoi membri: i payload sono firmati ma
  non cifrati (un membro malintenzionato non può forgere, solo leggere gli
  op). Per op sensibili future, valutare cifratura del payload (stesso HMAC
  come chiave KDF).
- HMAC a 32 byte hex generato con `randomBytes`: rotazione manuale (cambiare
  su server + Keychain). Nessun versionamento chiavi (protocollo `v:1` pronto).
- Rate limiting: assente oltre il naturale long-poll; un flood firmato
  correttamente è possibile solo con HMAC+token rubati (a quel punto ruotare).
- Windows: secrets protetti da ACL utente (non DPAPI) — miglioramento futuro.
