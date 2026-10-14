# Seitenplaner Zeitung

Eine einzelne HTML-Datei (`index.html`) zum Planen von Zeitungsseiten. Keine Installation, kein Server nötig.

## Satzspiegel (Berliner Format)

| | |
|---|---|
| Satzspiegel | 282,5 × 431 mm (B × H) |
| Spalten | 6 (Spaltenbreite 45 mm, Zwischenschlag 2,5 mm) |
| Seite gesamt | 2.586 spmm (6 × 431 mm) |

Spaltenbreiten: 1 = 45 mm, 2 = 92,5 mm, 3 = 140 mm, 4 = 187,5 mm, 5 = 235 mm, 6 = 282,5 mm.

## Gemeinsam planen über das Serverlaufwerk

1. `index.html` nach `O:\Gemeinsames` kopieren, z. B. als `O:\Gemeinsames\Seitenplaner.html`.
2. Die Datei in **Microsoft Edge** öffnen (Doppelklick, ggf. „Öffnen mit → Edge“). Tipp: als Favorit oder Desktop-Verknüpfung ablegen.
3. Beim ersten Mal auf **Ordner wählen** klicken und `O:\Gemeinsames` auswählen, dann den Zugriff erlauben.
   Der Planer legt darin den Unterordner `Seitenplanung` an; jede Zeitungsseite ist dort eine Datei `seite-….json`.
4. Bei späteren Starts fragt Edge evtl. noch einmal nach der Erlaubnis: ein Klick auf **Ordner verbinden** genügt.

- Änderungen der anderen erscheinen nach ca. 3 Sekunden.
- Unter „Dein Name“ eintragen, dann sehen die anderen, wer welche Seite geöffnet hat. Ist die eigene Seite gerade auch bei jemand anderem offen, erscheint ein Hinweis – gleichzeitige Änderungen an derselben Seite überschreiben sich (wer zuletzt speichert, gewinnt).
- Die Dateien `aktiv-….json` im Ordner zeigen nur an, wer gerade arbeitet; sie dürfen gelöscht werden.
- Firefox und Safari können nicht in Ordner schreiben; dort speichert der Planer nur im eigenen Browser.
- Der Ordner `Seitenplanung` wird von der normalen Serversicherung mit erfasst.

## Funktionen

- Flächen anlegen mit Spaltenzahl, Höhe in mm, Art (Artikel, Anzeige, Bild, Sonstiges) und Bezeichnung. Die Fläche landet an der ersten freien Stelle.
- Flächen mit der Maus verschieben: horizontal rasten sie in die Spalten ein, vertikal im gewählten Raster (1, 5 oder 10 mm).
- Mit gedrückter **Alt-Taste** ziehen: freie Platzierung außerhalb des Spaltenrasters in 0,5-mm-Schritten (gestrichelter Rahmen). Ohne Alt ziehen oder „Ins Raster setzen“ rastet wieder ein. Feld „Links (mm)“ setzt die Position exakt.
- Größe über die Ecke unten rechts ziehen oder exakt im Feld „Ausgewählte Fläche“ eingeben.
- Überlappende Flächen werden rot markiert; Belegung in Spaltenmillimetern (belegt / frei / Prozent).
- Mehrere Seiten anlegen, umbenennen, duplizieren, löschen; Miniaturansicht in der Seitenliste.
- Tastatur: Pfeiltasten verschieben (mit Alt in 0,5-mm-Schritten), Entf löscht, Strg+D dupliziert, Strg+Z macht rückgängig.
- **Exportieren** / **Importieren** (JSON-Datei) zum Sichern oder Weitergeben; **Drucken** gibt die aktuelle Seite verkleinert auf A4 aus.

Eine Online-Variante (claude.ai-Artifact) läuft aus derselben Quelle und speichert dort in der claude.ai-Ablage.
