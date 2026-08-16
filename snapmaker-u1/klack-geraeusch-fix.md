# Snapmaker U1 – dumpfes Klack-Geräusch beheben (Paxx-Firmware + Orca)

Stand: 2026-08-16 · Drucker: Snapmaker U1 · Firmware: Paxx Extended (v1.5.2-paxx12-21, basiert auf offizieller 1.5.2) · Drucker-IP im eigenen Netz: `192.168.31.218`

## Kurzfassung

Die Einstellungen sind **nicht** automatisch in der aktuellen Paxx-Firmware gesetzt. Nach einem Firmware- oder Orca-Update müssen **beide** Punkte erneut gesetzt werden:

1. **Orca:** Z-Hop-Typ `Auto` → `Normal`, für alle vier Extruder.
2. **Drucker/Klipper:** Z-Beschleunigung auf `200 mm/s²`.

Punkt 1 ist der größere Hebel, Punkt 2 dämpft den restlichen Schlag.

## Ursache

Snapmaker beschreibt das Geräusch offiziell als Z-Achsen-Klopfen: Bei schnellen Richtungswechseln der Z-Achse (vor allem beim Z-Hop) erzeugt der Z-Motor eine kurze Gegenkraft, die über die Mechanik in den Kunststoff-Unterbau übertragen wird → metallisch-dumpfes „Klack". Snapmaker stuft das als normal ein (kein Defekt), nennt aber genau zwei Gegenmaßnahmen — die beiden oben.

Warum es nach Updates wiederkommt:

- **Orca:** Der Z-Hop-Typ ist eine Drucker-Profil-Einstellung. Ein neues/aktualisiertes U1-Systemprofil in einer neuen Orca-Version setzt sie auf `Auto` zurück.
- **Firmware:** Änderungen direkt in der `printer.cfg` werden von einem Firmware-Update überschrieben.

---

## Teil 1 – Snapmaker Orca

Für **Extruder 1, 2, 3 und 4** jeweils einzeln:

```
Printer settings → Extruder N → Retraction → Z hop type:  Auto → Normal
```

`Auto` benutzt Spiral-/Slope-Lift; genau diese Bewegung löst das Klacken aus (in Extremfällen auch Layer-Shifts). `Normal` = gerader Lift.

Anschließend als **eigenes Benutzer-Preset speichern**, nicht im mitgelieferten Systemprofil arbeiten — dann überlebt die Einstellung das nächste Orca-Update.

---

## Teil 2 – Z-Beschleunigung am Drucker

### Schritt 0: Zugang freischalten

Am Touchscreen: `Einstellungen → Wartung → Advanced Mode` aktivieren.
Danach im Browser `http://192.168.31.218` öffnen → Fluidd (bzw. Mainsail, je nach Paxx-`firmware-config`).

Dabei prüfen, ob der Touchscreen im Advanced Mode bereits einen Punkt für **Z-Beschleunigung** anbietet. Falls ja: dort `200` setzen — das ist Snapmakers offizieller Weg, der Klipper-Teil entfällt dann. Nur falls dieser Punkt fehlt, weiter mit Schritt 1.

### Schritt 1: Include-Reihenfolge prüfen

In Fluidd links **Configuration** → `printer.cfg` öffnen → nach `[include` suchen.

Die Zeile, die `extended/klipper/...` einbindet, **muss weiter unten stehen als der `[printer]`-Block**. Bei doppelt definierten Optionen gewinnt in Klipper der zuletzt gelesene Wert. Bei Paxx sitzt der Include normalerweise am Ende. (Schritt 4 deckt auf, falls nicht.)

### Schritt 2: Config-Datei anlegen

Im **Configuration**-Tab in den Ordner `extended/klipper/` wechseln → neue Datei `z-noise-fix.cfg` mit diesem Inhalt:

```cfg
# Z-Klopfen reduzieren (Snapmaker-Empfehlung: 200 mm/s^2)
[printer]
max_z_accel: 200

# nur zur Kontrolle, dass diese Datei wirklich geladen wird
[gcode_macro Z_NOISE_FIX_CHECK]
gcode:
    RESPOND MSG="z-noise-fix.cfg ist aktiv"
```

Hinweise:

- Der einzelne `[printer]`-Eintrag genügt — die Sektion wird mit der aus `printer.cfg` zusammengeführt, `kinematics`, `max_velocity` usw. bleiben erhalten.
- `max_z_velocity` **nicht** anfassen, sonst werden Z-Hops spürbar langsamer.
- Alle `.cfg`-Dateien in `extended/klipper/` werden von der Paxx-Firmware automatisch eingebunden und bleiben über Neustarts erhalten. Das ist der vorgesehene Platz für eigene Tweaks — im Gegensatz zur `printer.cfg`.

### Schritt 3: Speichern & neu starten

**Save & Restart** in Fluidd, oder in der Konsole `FIRMWARE_RESTART`.

### Schritt 4: Verifizieren

1. Fluidd-Konsole: `Z_NOISE_FIX_CHECK` eingeben → erscheint die Meldung, wird die Datei geladen.
2. Aktiven Wert auslesen — im Browser öffnen:
   `http://192.168.31.218/printer/objects/query?configfile=settings`
   Im JSON nach `max_z_accel` suchen.
   - `200` → fertig.
   - noch der alte (hohe) Wert, obwohl Check 1 geklappt hat → Include-Reihenfolge (Schritt 1). Dann `max_z_accel` direkt in `printer.cfg` ändern; das muss nach **jedem** Firmware-Update wiederholt werden.

### Wenn Klipper nach dem Restart einen Fehler zeigt

Fluidd zeigt den Config-Fehler im Klartext und lässt die Datei weiter bearbeiten → Tippfehler korrigieren oder Datei löschen → `FIRMWARE_RESTART`.
Kommt Fluidd gar nicht mehr hoch: Paxx-USB-Wiederherstellung über `full-recover.txt` (ab v1.4.1-paxx12-20).

### Wertwahl

`200 mm/s²` ist Snapmakers Empfehlung. Falls Modelle mit sehr vielen Z-Hops merkbar länger drucken, sind `300`–`500` ein brauchbarer Kompromiss — Wert in derselben Datei ändern, Schritt 3 + 4 wiederholen.

---

## Falls es danach noch klackt

- **Z-Spindel schmieren** — Snapmaker nennt quartalsweise Wartung; eine trockene Spindel verstärkt das Geräusch deutlich.
- **Vibrationskompensation neu kalibrieren**, besonders bei montiertem Top Cover (fordert die Firmware ab 1.5.0 selbst an).
- **Experimentell, nur wenn alles andere nicht reicht:** Paxx-`firmware-config` → Tweaks → `TMC AutoTune` / `TMC Reduced Current`. Beides ist als experimentell markiert (reduzierter Motorstrom ⇒ Risiko von Schrittverlusten), und es gibt einen offenen Report über starke X-Vibrationen nach einem Paxx-Update (Issue #465).

## Warum es kein Automatik-Fix ist (Recherche-Stand 2026-08-16)

- Offizielle U1-Firmware 1.5.0 / 1.5.1 / 1.5.2: Top-Cover-Support und First-Layer-Fixes — nichts zu Z-Beschleunigung oder Z-Hop-Defaults.
- Paxx v1.5.2-paxx12-21: SpoolLink/Spoolman, Filament-Manager, Kamera-Fixes — nichts zum Klopf-Geräusch. Motion-seitig existieren nur die experimentellen TMC-Tweaks.

## Nach jedem Update abhaken

- [ ] Orca: Z hop type = `Normal` für Extruder 1–4 (eigenes Preset aktiv?)
- [ ] `extended/klipper/z-noise-fix.cfg` noch vorhanden?
- [ ] `max_z_accel` per Moonraker-Query = `200`?

## Quellen

- [U1 z-axis noise (thumping sound) – Snapmaker Wiki](https://wiki.snapmaker.com/en/snapmaker_u1/troubleshooting/z_hop_noise)
- U1 Firmware Release Notes: [V1.5.0](https://wiki.snapmaker.com/en/snapmaker_u1/firmware/release_notes/v150) · [V1.5.1](https://wiki.snapmaker.com/en/snapmaker_u1/firmware/release_notes/v151) · [V1.5.2](https://wiki.snapmaker.com/en/snapmaker_u1/firmware/release_notes/v152)
- [Paxx Extended Firmware – Releases](https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware/releases)
- Paxx-Doku: [firmware_config](https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware/blob/develop/docs/firmware_config.md) · [klipper_includes](https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware/blob/develop/docs/klipper_includes.md)
- [Issue #465 – starke X-Vibrationen nach Paxx-Update](https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware/issues/465)

Einschränkung zur Quellenlage: `wiki.snapmaker.com`, `forum.snapmaker.com` und die Paxx-Doku-Website waren aus der Recherche-Umgebung per Egress-Proxy gesperrt. Die Wiki-Inhalte stammen aus Suchergebnis-Auszügen, die Paxx-Details direkt aus dem GitHub-Repo. Die exakte Menüführung für den Z-Accel-Wert am Touchscreen ab „Advanced Mode" konnte nicht Klick für Klick verifiziert werden — der Klipper-Weg ist ohnehin der robustere.
