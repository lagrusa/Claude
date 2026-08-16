# Runbook für Claude Code: Z-Klack-Fix auf dem Snapmaker U1 ausführen

Zielgerät: Snapmaker U1, Paxx Extended Firmware, erreichbar unter `http://192.168.31.218`
Hintergrund und Begründung: siehe `klack-geraeusch-fix.md` im selben Ordner.

**Voraussetzung:** Diese Session muss im **selben LAN** wie der Drucker laufen (Cloud-Sessions können private IPs nicht erreichen). Zuerst am Touchscreen `Einstellungen → Wartung → Advanced Mode` aktivieren, sonst ist die Weboberfläche/API zu.

Alle Kommandos setzen `curl` und `jq` voraus. Ohne `jq`: `python3 -m json.tool` verwenden.
Bei `401 Unauthorized`: API-Key aus Fluidd (`Settings → API keys`) holen und jedem Aufruf `-H "X-Api-Key: <KEY>"` mitgeben.

---

## Ablauf

### Schritt 1 – Erreichbarkeit und Klipper-Status

```bash
curl -s http://192.168.31.218/printer/info | jq '{state: .result.state, msg: .result.state_message}'
```

Erwartung: `state` = `ready`. Bei `error` zuerst die Meldung klären — **nicht** blind weitermachen.

### Schritt 2 – Sicherheitscheck: läuft ein Druck?

```bash
curl -s "http://192.168.31.218/printer/objects/query?print_stats" \
  | jq -r '.result.status.print_stats.state'
```

**Abbruchbedingung:** Bei `printing` oder `paused` hier stoppen und den Benutzer fragen. Schritt 6 startet Klipper neu und würde einen laufenden Druck abbrechen.

### Schritt 3 – Ausgangswert festhalten

```bash
curl -s "http://192.168.31.218/printer/objects/query?configfile=settings" \
  | jq '.result.status.configfile.settings.printer'
```

Den aktuellen `max_z_accel`-Wert notieren und dem Benutzer nennen (Rollback-Referenz).

### Schritt 4 – Include-Reihenfolge in `printer.cfg` prüfen

```bash
curl -s http://192.168.31.218/server/files/config/printer.cfg -o /tmp/printer.cfg
grep -n -E '^\[printer\]|^\[include' /tmp/printer.cfg
```

Die Zeilennummer des Includes, der `extended/klipper/...` einbindet, **muss größer sein** als die von `[printer]` — bei doppelt definierten Optionen gewinnt in Klipper der zuletzt gelesene Wert.

- Include **danach** → weiter mit Schritt 5.
- Include **davor** → der Override greift nicht. Dann Schritt 5–6 überspringen und dem Benutzer melden: nur direkte Änderung in `printer.cfg` möglich, die aber jedes Firmware-Update überschreibt. **Nicht ohne Rückfrage** in `printer.cfg` schreiben.

### Schritt 5 – Override-Datei hochladen

```bash
cat > /tmp/z-noise-fix.cfg <<'EOF'
# Z-Klopfen reduzieren (Snapmaker-Empfehlung: 200 mm/s^2)
[printer]
max_z_accel: 200

# Marker, um zu prüfen, ob diese Datei geladen wird
[gcode_macro Z_NOISE_FIX_CHECK]
gcode:
    {action_respond_info("z-noise-fix.cfg ist aktiv")}
EOF

curl -s -F "root=config" -F "path=extended/klipper" \
     -F "file=@/tmp/z-noise-fix.cfg" \
     http://192.168.31.218/server/files/upload | jq
```

Landet die Datei nicht im Unterordner, stattdessen den Pfad in den Dateinamen legen:

```bash
curl -s -F "root=config" \
     -F "file=@/tmp/z-noise-fix.cfg;filename=extended/klipper/z-noise-fix.cfg" \
     http://192.168.31.218/server/files/upload | jq
```

Kontrolle:

```bash
curl -s "http://192.168.31.218/server/files/list?root=config" \
  | jq -r '.result[].path' | grep z-noise-fix
```

Hinweise:

- `[printer]` hier nur mit dieser einen Option — die Sektion wird mit der aus `printer.cfg` zusammengeführt, `kinematics`/`max_velocity` bleiben erhalten.
- `max_z_velocity` **nicht** verändern.
- Im Marker-Makro bewusst `action_respond_info(...)` statt `RESPOND`/`M118`: letztere brauchen ein `[respond]`-Modul in der Config und würden sonst selbst einen Config-Fehler auslösen.

### Schritt 6 – Klipper neu starten

```bash
curl -s -X POST http://192.168.31.218/printer/firmware_restart
```

Danach pollen, bis `ready` (bis zu ~60 s):

```bash
for i in $(seq 1 20); do
  sleep 3
  curl -s http://192.168.31.218/printer/info \
    | jq -r '"\(.result.state): \(.result.state_message)"'
done
```

### Schritt 7 – Verifizieren

```bash
# a) greift der Wert?
curl -s "http://192.168.31.218/printer/objects/query?configfile=settings" \
  | jq '.result.status.configfile.settings.printer.max_z_accel'

# b) wird die Datei überhaupt geladen?
curl -s http://192.168.31.218/printer/objects/list \
  | jq -r '.result.objects[]' | grep -i z_noise_fix
```

- (a) = `200` und (b) findet `gcode_macro Z_NOISE_FIX_CHECK` → fertig, dem Benutzer bestätigen.
- (b) findet nichts → Datei liegt am falschen Ort (Schritt 5 wiederholen, Pfad prüfen).
- (b) ok, (a) noch der alte Wert → Include-Reihenfolge, siehe Schritt 4.

Optional, erzeugt eine sichtbare Meldung in der Fluidd-Konsole:

```bash
curl -s -X POST "http://192.168.31.218/printer/gcode/script?script=Z_NOISE_FIX_CHECK"
```

---

## Rollback / Fehlerfall

Klipper startet nach Schritt 6 mit `error` (Config-Fehler) oder etwas soll zurückgenommen werden:

```bash
curl -s -X DELETE "http://192.168.31.218/server/files/config/extended/klipper/z-noise-fix.cfg"
curl -s -X POST http://192.168.31.218/printer/firmware_restart
```

Kommt die API gar nicht mehr hoch: Paxx-USB-Wiederherstellung über `full-recover.txt` (ab v1.4.1-paxx12-20) — das ist ein manueller Schritt am Gerät.

## Grenzen für Claude Code – ohne Rückfrage nicht tun

- **Nicht** in `printer.cfg` schreiben (wird von Firmware-Updates überschrieben, und ein Fehler dort blockiert den Klipper-Start).
- **Nicht** neu starten, während ein Druck läuft (Schritt 2).
- **Nicht** `max_z_velocity`, Motorströme oder TMC-Einstellungen anfassen — nicht Teil dieser Aufgabe.
- Werte außerhalb `200`–`500` für `max_z_accel` nur auf ausdrücklichen Wunsch.

---

## Teil 2: Snapmaker Orca (der größere Hebel)

Der Klipper-Teil dämpft nur den Schlag; Auslöser ist der Spiral-Lift im Slicer. Das ist ein GUI-Schritt und bleibt manuell:

`Printer settings → Extruder 1…4 → Retraction → Z hop type: Auto → Normal`, danach als eigenes Benutzer-Preset speichern.

Falls Claude Code das doch per Datei erledigen soll: Orca legt Benutzer-Drucker-Presets als JSON ab (Windows `%APPDATA%\<Orca-Ordner>\user\default\machine\*.json`, macOS `~/Library/Application Support/<Orca-Ordner>`, Linux `~/.config/<Orca-Ordner>`; der Ordnername unterscheidet sich zwischen OrcaSlicer und Snapmaker Orca). Relevant ist der Schlüssel `z_hop_types` mit einem Eintrag pro Extruder.

Dabei zwingend: **vorhandene Datei erst lesen** und die dort verwendete Schreibweise der Werte exakt übernehmen (Orca nutzt Strings wie `Auto Lift` / `Normal Lift`) — nicht raten, sonst weigert sich Orca beim Laden des Profils. Orca vor der Änderung schließen, danach Profil in der GUI kontrollieren. Systemprofile nicht anfassen, nur Benutzer-Presets.

---

## Kurzstatus, den Claude Code am Ende melden soll

1. `max_z_accel` vorher → nachher
2. Marker-Makro vorhanden ja/nein
3. Include-Reihenfolge ok ja/nein
4. Offen: Orca-Teil (Z hop type `Normal` für Extruder 1–4)
