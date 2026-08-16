#!/usr/bin/env bash
# Snapmaker U1 (Paxx-Firmware): Z-Klopfen reduzieren, indem max_z_accel gesenkt wird.
#
# Muss auf einem Rechner im selben Netz wie der Drucker laufen.
# Benoetigt nur curl. Idempotent - mehrfaches Ausfuehren ist unschaedlich.
#
#   bash apply-z-noise-fix.sh [DRUCKER-IP]
#
# Optional:
#   ACCEL=300 bash apply-z-noise-fix.sh          # anderer Beschleunigungswert
#   MOONRAKER_API_KEY=xxx bash apply-z-noise-fix.sh
#   bash apply-z-noise-fix.sh --rollback         # Aenderung zuruecknehmen

set -uo pipefail

ROLLBACK=0
HOST=192.168.31.218
for arg in "$@"; do
  case "$arg" in
    --rollback) ROLLBACK=1 ;;
    -*) echo "Unbekannte Option: $arg" >&2; exit 2 ;;
    *) HOST="$arg" ;;
  esac
done

ACCEL="${ACCEL:-200}"
API="http://$HOST"
CFG_PATH="extended/klipper/z-noise-fix.cfg"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

req() {  # req METHOD PFAD [curl-args...]
  local method="$1" path="$2"; shift 2
  local args=(-sS --max-time 20 -X "$method")
  [ -n "${MOONRAKER_API_KEY:-}" ] && args+=(-H "X-Api-Key: $MOONRAKER_API_KEY")
  curl "${args[@]}" "$@" "$API$path"
}

# Minimal-Parser, damit kein jq gebraucht wird.
jval() { grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*"\([^"]*\)"$/\1/'; }
nval() { grep -o "\"$1\"[[:space:]]*:[[:space:]]*[0-9.]*"    | head -1 | sed 's/.*:[[:space:]]*//'; }

die() { echo "FEHLER: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

# ---------------------------------------------------------------- Schritt 1
step "1/7 Drucker erreichbar?"
info="$(req GET /printer/info 2>&1)" || die "$API nicht erreichbar. Laeuft dieser Rechner im selben WLAN wie der Drucker? Ist am Touchscreen 'Einstellungen -> Wartung -> Advanced Mode' aktiv?"
case "$info" in
  *Unauthorized*|*unauthorized*) die "Moonraker verlangt Authentifizierung. API-Key in Fluidd unter Settings -> API keys holen und erneut starten: MOONRAKER_API_KEY=<key> bash $0 $HOST" ;;
esac
kstate="$(printf '%s' "$info" | jval state)"
[ -n "$kstate" ] || die "Unerwartete Antwort von $API/printer/info: $info"
echo "Klipper-Status: $kstate"
[ "$kstate" = "ready" ] || echo "WARNUNG: Klipper ist nicht 'ready' - Meldung: $(printf '%s' "$info" | jval state_message)"

# ---------------------------------------------------------------- Schritt 2
step "2/7 Laeuft gerade ein Druck?"
pstate="$(req GET "/printer/objects/query?print_stats" | jval state)"
echo "Druckstatus: ${pstate:-unbekannt}"
case "$pstate" in
  printing|paused) die "Es laeuft ein Druck ($pstate). Dieses Skript startet Klipper neu und wuerde ihn abbrechen. Bitte spaeter erneut ausfuehren." ;;
esac

# ---------------------------------------------------------------- Rollback
if [ "$ROLLBACK" = 1 ]; then
  step "Rollback: $CFG_PATH loeschen"
  req DELETE "/server/files/config/$CFG_PATH"; echo
  req POST /printer/firmware_restart >/dev/null
  echo "Geloescht und Klipper neu gestartet. Alter Wert ist wieder aktiv."
  exit 0
fi

# ---------------------------------------------------------------- Schritt 3
step "3/7 Aktuellen Wert lesen"
before="$(req GET "/printer/objects/query?configfile=settings" | nval max_z_accel)"
echo "max_z_accel vorher: ${before:-unbekannt}"
if [ -n "$before" ] && [ "${before%%.*}" = "${ACCEL%%.*}" ]; then
  echo "Wert steht bereits auf $ACCEL - es gibt nichts zu tun."
fi

# ---------------------------------------------------------------- Schritt 4
step "4/7 Include-Reihenfolge in printer.cfg pruefen"
req GET /server/files/config/printer.cfg -o "$TMP/printer.cfg" || die "printer.cfg nicht abrufbar."
printer_line="$(grep -n '^\[printer\]' "$TMP/printer.cfg" | head -1 | cut -d: -f1)"
inc_line="$(grep -n '^\[include.*extended' "$TMP/printer.cfg" | tail -1 | cut -d: -f1)"
echo "[printer] in Zeile ${printer_line:-?}, extended-Include in Zeile ${inc_line:-keiner}"
if [ -z "$inc_line" ]; then
  die "Kein Include fuer extended/klipper gefunden. Ist wirklich die Paxx-Firmware installiert? Ohne diesen Include wird die Override-Datei nicht geladen."
fi
if [ -n "$printer_line" ] && [ "$inc_line" -lt "$printer_line" ]; then
  die "Der extended-Include steht VOR dem [printer]-Block. Ein Override greift so nicht - der Wert muesste direkt in printer.cfg geaendert werden (geht bei jedem Firmware-Update verloren). Dieses Skript aendert printer.cfg absichtlich nicht."
fi

# ---------------------------------------------------------------- Schritt 5
step "5/7 Override-Datei hochladen"
cat > "$TMP/z-noise-fix.cfg" <<EOF
# Z-Klopfen reduzieren (Snapmaker-Empfehlung: 200 mm/s^2)
# Angelegt von apply-z-noise-fix.sh
[printer]
max_z_accel: $ACCEL

# Marker, um zu pruefen, ob diese Datei geladen wird.
# Bewusst action_respond_info statt RESPOND/M118 - die brauchen ein [respond]-Modul.
[gcode_macro Z_NOISE_FIX_CHECK]
gcode:
    {action_respond_info("z-noise-fix.cfg ist aktiv, max_z_accel=$ACCEL")}
EOF

up="$(req POST /server/files/upload -F "root=config" -F "path=extended/klipper" -F "file=@$TMP/z-noise-fix.cfg")"
if ! printf '%s' "$up" | grep -q 'z-noise-fix.cfg'; then
  echo "Erster Upload-Versuch ohne Erfolg, versuche Pfad im Dateinamen..."
  up="$(req POST /server/files/upload -F "root=config" -F "file=@$TMP/z-noise-fix.cfg;filename=$CFG_PATH")"
fi
req GET "/server/files/list?root=config" | grep -q 'z-noise-fix.cfg' \
  || die "Upload fehlgeschlagen. Antwort war: $up"
echo "Hochgeladen nach config/$CFG_PATH"

# ---------------------------------------------------------------- Schritt 6
step "6/7 Klipper neu starten"
req POST /printer/firmware_restart >/dev/null
for _ in $(seq 1 20); do
  sleep 3
  info="$(req GET /printer/info 2>/dev/null)"
  kstate="$(printf '%s' "$info" | jval state)"
  printf '.'
  [ "$kstate" = "ready" ] && break
  [ "$kstate" = "error" ] && break
done
echo " Status: ${kstate:-unbekannt}"

if [ "$kstate" = "error" ]; then
  echo "Klipper meldet einen Fehler:"
  printf '%s\n' "$info" | jval state_message
  echo "Nehme die Aenderung automatisch zurueck..."
  req DELETE "/server/files/config/$CFG_PATH" >/dev/null
  req POST /printer/firmware_restart >/dev/null
  die "Config wurde zurueckgenommen, Klipper neu gestartet. Bitte die Fehlermeldung oben melden."
fi

# ---------------------------------------------------------------- Schritt 7
step "7/7 Verifizieren"
after="$(req GET "/printer/objects/query?configfile=settings" | nval max_z_accel)"
if req GET /printer/objects/list | grep -qi 'Z_NOISE_FIX_CHECK'; then
  marker="ja"
else
  marker="nein"
fi

echo
echo "-------------------------------------------"
echo "max_z_accel:      ${before:-?}  ->  ${after:-?}"
echo "Marker-Makro:     $marker"
echo "Config-Datei:     config/$CFG_PATH"
echo "-------------------------------------------"

if [ "${after%%.*}" = "${ACCEL%%.*}" ] && [ "$marker" = "ja" ]; then
  echo "Fertig. Noch offen (GUI, nicht automatisierbar):"
  echo "  Snapmaker Orca -> Printer settings -> Extruder 1..4 -> Retraction"
  echo "  -> 'Z hop type' von Auto auf Normal, danach als eigenes Preset speichern."
  echo "Das ist der groessere Hebel gegen das Klacken."
elif [ "$marker" = "nein" ]; then
  die "Die Datei wird nicht geladen. Pfad in Fluidd unter Configuration pruefen (config/$CFG_PATH)."
else
  die "Datei wird geladen, aber max_z_accel ist noch ${after:-?}. Vermutlich Include-Reihenfolge - siehe claude-code-runbook-klack-fix.md, Schritt 4."
fi
