# MCP-Server: Klipper/Moonraker am Snapmaker U1

Gibt Claude Code typisierte Werkzeuge für den Drucker, statt curl-Kommandos.

## Das Wichtigste zuerst: was ein MCP-Server nicht löst

Die Hürde ist **kein fehlendes Werkzeug, sondern das Netz**. Ein MCP-Server läuft immer dort, wo die
Claude-Code-Session läuft. Eine Cloud-Session (Claude Code im Browser, Container im Rechenzentrum)
kommt an `192.168.31.218` nicht heran — private Adressen werden vom Egress-Proxy abgewiesen
(`403 x-deny-reason: private_dest_ip`). Derselbe Server, lokal gestartet, funktioniert sofort.

Deshalb: **lokale Claude-Code-Session am Rechner im eigenen WLAN.** Damit ist der Drucker
erreichbar, ohne ihn irgendwo im Internet zu veröffentlichen.

## Einrichtung (lokal, ~1 Minute)

Repo klonen (falls noch nicht vorhanden) und den Server registrieren:

```bash
git clone https://github.com/lagrusa/Claude.git
cd Claude

claude mcp add snapmaker-u1 \
  --env MOONRAKER_URL=http://192.168.31.218 \
  -- python3 "$PWD/snapmaker-u1/mcp/moonraker_mcp.py"
```

Alternativ per Datei `.mcp.json` im Projektverzeichnis:

```json
{
  "mcpServers": {
    "snapmaker-u1": {
      "command": "python3",
      "args": ["snapmaker-u1/mcp/moonraker_mcp.py"],
      "env": { "MOONRAKER_URL": "http://192.168.31.218" }
    }
  }
}
```

Voraussetzungen: Python 3 (Standardbibliothek genügt, keine Pakete), und am Touchscreen
`Einstellungen → Wartung → Advanced Mode` aktiv. Falls Moonraker einen API-Key verlangt
(`401`), zusätzlich `MOONRAKER_API_KEY` setzen — Key in Fluidd unter `Settings → API keys`.

Prüfen, ob der Server sauber startet, ohne Claude Code:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  | MOONRAKER_URL=http://192.168.31.218 python3 snapmaker-u1/mcp/moonraker_mcp.py
```

## Werkzeuge

| Tool | Wirkung |
| --- | --- |
| `klipper_status` | Klipper-Zustand, laufender Druck, `max_z_accel`, Include-Reihenfolge, ob die Override-Datei liegt. Nur lesend. |
| `klipper_list_config` | Config-Dateien auflisten. Nur lesend. |
| `klipper_read_config` | Config-Datei lesen, Standard `printer.cfg`. Nur lesend. |
| `klipper_apply_z_accel` | `max_z_accel` setzen (Standard 200): Datei anlegen, Klipper neu starten, verifizieren. |
| `klipper_rollback_z_accel` | Override-Datei löschen, Klipper neu starten. |

Danach genügt in Claude Code: *„setze die Z-Beschleunigung am U1 auf 200"* — oder erst
*„zeig mir den Druckerstatus"*.

## Eingebaute Sicherungen

- **Kein Neustart bei laufendem Druck.** `klipper_apply_z_accel` bricht bei `printing`/`paused` ab.
- **Auto-Rollback.** Kommt Klipper nach dem Neustart nicht auf `ready`, wird die Datei entfernt und
  erneut neu gestartet, damit der Drucker nicht in einem Config-Fehler stehen bleibt.
- **`printer.cfg` wird nie geschrieben.** Nur `extended/klipper/z-noise-fix.cfg` — Firmware-Update-fest
  und ohne Risiko, die Hauptkonfiguration zu zerlegen.
- **Wertgrenzen.** `accel` nur zwischen 50 und 1000 mm/s².
- **Kein freier G-Code-Passthrough.** Absichtlich weggelassen: das würde Kontrolle über Heizungen
  und Bewegung bedeuten, die für diese Aufgabe niemand braucht. Falls du es später willst, ist es
  ein kurzer Zusatz — aber dann als bewusste Entscheidung.

## Getestet

Gegen einen Moonraker-Mock geprüft: MCP-Handshake (`initialize`, `tools/list`, `tools/call`),
Erfolgsfall (`800 → 200`, Marker-Makro geladen), Wert außerhalb der Grenzen, Rollback,
Config-Fehler mit automatischem Rollback und nicht erreichbarer Drucker. Nicht gegen den echten
Drucker getestet — das passiert beim ersten lokalen Lauf, deshalb prüft jedes Tool sein Ergebnis
selbst und meldet Abweichungen im Klartext.

## Wenn es doch aus der Cloud erreichbar sein soll

Möglich wäre es nur, indem Moonraker von außen erreichbar gemacht wird — VPN/Tailscale
(in der Paxx-Firmware unter `remote_access`), OctoEverywhere (in Paxx enthalten) oder ein
Reverse-Proxy/Cloudflare-Tunnel.

Ehrliche Einschätzung: Moonraker hat standardmäßig **keine Authentifizierung** und erlaubt
Dateizugriff, G-Code-Ausführung und Heizungssteuerung. Direkt ins Internet gestellt ist das ein
echtes Risiko — Feuergefahr inklusive, nicht bloß Datenschutz. Wenn Fernzugriff, dann VPN
(nur für dich, kein offener Port) und nicht als Agenten-Kanal. Der lokale Weg ist für diese
Aufgabe schlicht der bessere.
