# TESTING

## Unit tests (no deps, no network)

```bash
npm install   # una volta: typescript, @types/node, typebox, pi types
npm test      # node --test "tests/*.test.ts"  → 32 test
npm run typecheck  # tsc --noEmit
```

Copertura reale (non finta):

| Area | Casi |
| --- | --- |
| Firma | valida, errata, secret sbagliato, payload manomesso byte-exact |
| Freshness | scaduto (`ts_expired`), futuro (`ts_future`), al limite skew |
| Forma | prefissi/forme malformate, payload non-oggetto, op non valida (`run_command` rifiutata) |
| Risposte | correlazione `requestId`, verifica con stesso HMAC, rifiuto con altro secret |
| Replay store | duplicati, persistenza dopo restart (rilettura file), expiry + prune, last update/error |
| Atomicità | scrittura valida, nessun tmp residuo, overwrite, backup, fallback su file corrotti |
| Moduli | patch valida + merge, campi ignoti (`filePath`, `shellCommand`, `command`, `script`…), tipi errati, range, patch vuote/enormi/non-oggetto, nomi file con traversal rifiutati |

## Live checklist (richiede Telegram reale, una volta)

1. `getMe` per entrambi i bot (fatto dagli setup script).
2. Mac → server: `remote_server_status` → risposta firmata < 90s.
3. Mac → server: `set_config` valido → conferma `✅` + backup creato in `server-config/`.
4. Mac → server: `set_config` con campo ignoto → `invalid_patch`, file intatto.
5. Replay: rimanda lo stesso messaggio (copia dal gruppo) → `replay`, ignorato.
6. Prefisso con firma rotta → consumato, mai al modello, `rejected` in `remote-state.json`.
7. Reboot server → `pi-server` online senza login; `/telegram-connect`
   automatico (log `[pi-server]` nel PM2/Task Scheduler).
8. Telefono → DM ServerBot: `stato server`, `disattiva example-monitor`,
   `quali servizi stanno girando`.

## Limiti noti dei test automatici

- Il flusso Telegram end-to-end non è simulabile senza bot reali (niente mock
  finti della Bot API): i casi sopra sono checklist manuale.
- `pi-daemon.mjs` + `ecosystem.config.cjs` si verificano sul server
  (`pm2 logs pi-server`, `pm2 describe pi-server`) — non in CI.
- Le extension vengono typecheckate (`tsc`) ma il caricamento jiti reale si
  prova con `pi` + `/reload` e `session_start` notify.
