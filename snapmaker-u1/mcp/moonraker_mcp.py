#!/usr/bin/env python3
"""
MCP-Server fuer Moonraker/Klipper auf dem Snapmaker U1 (Paxx-Firmware).

Laeuft per stdio, ohne externe Abhaengigkeiten (nur Python-Standardbibliothek).
Muss auf einem Rechner im selben Netz wie der Drucker laufen - eine
Cloud-Session (Claude Code im Browser/Container) kann private IPs nicht
erreichen, daran aendert auch dieser Server nichts.

Konfiguration ueber Umgebungsvariablen:
    MOONRAKER_URL      Standard: http://192.168.31.218
    MOONRAKER_API_KEY  optional, nur falls Moonraker Authentifizierung verlangt

Bereitgestellte Tools:
    klipper_status          Drucker-/Druckstatus und aktuelle Z-Beschleunigung
    klipper_list_config     Config-Dateien auflisten
    klipper_read_config     eine Config-Datei lesen (z. B. printer.cfg)
    klipper_apply_z_accel   max_z_accel setzen (Upload + Restart + Verifikation)
    klipper_rollback_z_accel  Aenderung zuruecknehmen

Absichtlich NICHT enthalten: ein freier G-Code-Passthrough. Der wuerde dem
Agenten Kontrolle ueber Heizung und Bewegung geben, was fuer diese Aufgabe
nicht gebraucht wird.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

SERVER_NAME = "snapmaker-u1-moonraker"
SERVER_VERSION = "1.0.0"
DEFAULT_URL = "http://192.168.31.218"
CFG_PATH = "extended/klipper/z-noise-fix.cfg"
PROTOCOL_FALLBACK = "2024-11-05"


def base_url() -> str:
    return os.environ.get("MOONRAKER_URL", DEFAULT_URL).rstrip("/")


class MoonrakerError(RuntimeError):
    pass


def request(method: str, path: str, *, data: bytes = None, content_type: str = None, raw: bool = False,
            timeout: int = 20):
    req = urllib.request.Request(base_url() + path, data=data, method=method)
    if content_type:
        req.add_header("Content-Type", content_type)
    key = os.environ.get("MOONRAKER_API_KEY")
    if key:
        req.add_header("X-Api-Key", key)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:400]
        if exc.code in (401, 403):
            raise MoonrakerError(
                f"HTTP {exc.code} von {base_url()}{path}. Falls Moonraker einen API-Key verlangt: "
                f"Key in Fluidd unter Settings -> API keys holen und als MOONRAKER_API_KEY setzen. "
                f"Antwort: {detail}") from None
        raise MoonrakerError(f"HTTP {exc.code} von {path}: {detail}") from None
    except urllib.error.URLError as exc:
        raise MoonrakerError(
            f"{base_url()} nicht erreichbar ({exc.reason}). Laeuft dieser Rechner im selben Netz wie der "
            f"Drucker? Private Adressen sind aus Cloud-Sessions grundsaetzlich nicht erreichbar. "
            f"Ist am Touchscreen 'Einstellungen -> Wartung -> Advanced Mode' aktiv?") from None
    if raw:
        return body.decode("utf-8", "replace")
    try:
        return json.loads(body.decode("utf-8", "replace"))
    except json.JSONDecodeError:
        raise MoonrakerError(f"Keine JSON-Antwort von {path}: {body[:200]!r}") from None


def printer_state() -> dict:
    result = request("GET", "/printer/info").get("result", {})
    return {"state": result.get("state"), "message": result.get("state_message")}


def print_state() -> str:
    result = request("GET", "/printer/objects/query?print_stats").get("result", {})
    return result.get("status", {}).get("print_stats", {}).get("state", "unbekannt")


def printer_settings() -> dict:
    result = request("GET", "/printer/objects/query?configfile=settings").get("result", {})
    return result.get("status", {}).get("configfile", {}).get("settings", {}).get("printer", {})


def config_files() -> list:
    result = request("GET", "/server/files/list?root=config").get("result", [])
    return [item.get("path") for item in result if isinstance(item, dict)]


def objects_list() -> list:
    return request("GET", "/printer/objects/list").get("result", {}).get("objects", [])


def upload_config(path: str, content: str) -> dict:
    """Datei in den config-Root hochladen. path ist relativ, z. B. extended/klipper/x.cfg."""
    folder, _, name = path.rpartition("/")
    boundary = "----moonrakermcp7f3a91"
    parts = []

    def field(key, value):
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n')

    field("root", "config")
    if folder:
        field("path", folder)
    parts.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\n'
        f"Content-Type: application/octet-stream\r\n\r\n{content}\r\n")
    parts.append(f"--{boundary}--\r\n")
    body = "".join(parts).encode("utf-8")
    return request("POST", "/server/files/upload", data=body,
                   content_type=f"multipart/form-data; boundary={boundary}", timeout=30)


def delete_config(path: str) -> dict:
    return request("DELETE", f"/server/files/config/{path}")


def firmware_restart_and_wait(timeout: int = 75) -> dict:
    request("POST", "/printer/firmware_restart")
    deadline = time.time() + timeout
    last = {"state": "unbekannt", "message": ""}
    time.sleep(3)
    while time.time() < deadline:
        try:
            last = printer_state()
        except MoonrakerError:
            last = {"state": "neustart", "message": "API noch nicht erreichbar"}
        if last.get("state") in ("ready", "error", "shutdown"):
            return last
        time.sleep(3)
    return last


def include_order_ok() -> tuple:
    """(ok, hinweis) - liegt der extended-Include hinter dem [printer]-Block?"""
    try:
        cfg = request("GET", "/server/files/config/printer.cfg", raw=True)
    except MoonrakerError as exc:
        return None, f"printer.cfg nicht lesbar: {exc}"
    printer_line = include_line = None
    for number, line in enumerate(cfg.splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("[printer]") and printer_line is None:
            printer_line = number
        if stripped.startswith("[include") and "extended" in stripped:
            include_line = number
    if include_line is None:
        return False, ("Kein Include fuer extended/klipper in printer.cfg gefunden - ohne diesen Include "
                       "wird eine Override-Datei nicht geladen (Paxx-Firmware installiert?).")
    if printer_line is not None and include_line < printer_line:
        return False, (f"Der extended-Include (Zeile {include_line}) steht vor dem [printer]-Block "
                       f"(Zeile {printer_line}). Ein Override greift so nicht; der Wert muesste direkt in "
                       f"printer.cfg geaendert werden, was jedes Firmware-Update ueberschreibt.")
    return True, f"[printer] Zeile {printer_line}, extended-Include Zeile {include_line}"


# --------------------------------------------------------------------- Tools

def tool_status(_args: dict) -> str:
    state = printer_state()
    settings = printer_settings()
    ok, hint = include_order_ok()
    lines = [
        f"Drucker:            {base_url()}",
        f"Klipper-Status:     {state.get('state')} ({state.get('message')})",
        f"Druckstatus:        {print_state()}",
        f"max_z_accel:        {settings.get('max_z_accel')}",
        f"max_z_velocity:     {settings.get('max_z_velocity')}",
        f"max_accel (XY):     {settings.get('max_accel')}",
        f"Include-Reihenfolge: {'ok' if ok else 'PROBLEM'} - {hint}",
        f"Override-Datei:     {'vorhanden' if CFG_PATH in config_files() else 'nicht vorhanden'}",
    ]
    return "\n".join(lines)


def tool_list_config(_args: dict) -> str:
    return "\n".join(config_files()) or "(keine Dateien)"


def tool_read_config(args: dict) -> str:
    path = args.get("path", "printer.cfg")
    return request("GET", f"/server/files/config/{path}", raw=True)


def tool_apply(args: dict) -> str:
    accel = args.get("accel", 200)
    try:
        accel = float(accel)
    except (TypeError, ValueError):
        raise MoonrakerError(f"accel muss eine Zahl sein, war: {args.get('accel')!r}")
    if not 50 <= accel <= 1000:
        raise MoonrakerError(f"accel={accel} liegt ausserhalb des plausiblen Bereichs 50-1000 mm/s^2.")

    state = printer_state()
    log = [f"Klipper-Status vorher: {state.get('state')}"]

    running = print_state()
    if running in ("printing", "paused"):
        raise MoonrakerError(f"Es laeuft ein Druck ({running}). Ein FIRMWARE_RESTART wuerde ihn abbrechen - "
                             f"abgebrochen, bitte spaeter erneut versuchen.")
    log.append(f"Druckstatus: {running}")

    before = printer_settings().get("max_z_accel")
    log.append(f"max_z_accel vorher: {before}")

    ok, hint = include_order_ok()
    log.append(f"Include-Reihenfolge: {hint}")
    if ok is False:
        raise MoonrakerError(hint + " Es wurde nichts geaendert; printer.cfg wird von diesem Server "
                                    "bewusst nicht angetastet.")

    content = (
        "# Z-Klopfen reduzieren (Snapmaker-Empfehlung: 200 mm/s^2)\n"
        "# Angelegt vom MCP-Server snapmaker-u1-moonraker\n"
        "[printer]\n"
        f"max_z_accel: {accel:g}\n\n"
        "# Marker, um zu pruefen, ob diese Datei geladen wird.\n"
        "# action_respond_info statt RESPOND/M118 - die brauchen ein [respond]-Modul.\n"
        "[gcode_macro Z_NOISE_FIX_CHECK]\n"
        "gcode:\n"
        f'    {{action_respond_info("z-noise-fix.cfg ist aktiv, max_z_accel={accel:g}")}}\n'
    )
    upload_config(CFG_PATH, content)
    if CFG_PATH not in config_files():
        raise MoonrakerError("Upload hat die Datei nicht an der erwarteten Stelle abgelegt "
                             f"({CFG_PATH}). Es wurde kein Neustart ausgeloest.")
    log.append(f"Datei hochgeladen: config/{CFG_PATH}")

    after_restart = firmware_restart_and_wait()
    log.append(f"Nach FIRMWARE_RESTART: {after_restart.get('state')}")

    if after_restart.get("state") != "ready":
        delete_config(CFG_PATH)
        firmware_restart_and_wait()
        raise MoonrakerError(
            f"Klipper kam nicht sauber hoch ({after_restart.get('state')}): {after_restart.get('message')}\n"
            f"Die Datei wurde automatisch wieder entfernt und Klipper neu gestartet.")

    after = printer_settings().get("max_z_accel")
    marker = any("Z_NOISE_FIX_CHECK" in str(obj) for obj in objects_list())
    log.append(f"max_z_accel nachher: {after}")
    log.append(f"Marker-Makro geladen: {'ja' if marker else 'nein'}")

    if not marker:
        log.append("WARNUNG: Die Datei wird offenbar nicht eingebunden - Pfad pruefen.")
    elif after is None or abs(float(after) - accel) > 0.01:
        log.append("WARNUNG: Datei wird geladen, aber der Wert greift nicht - Include-Reihenfolge pruefen.")
    else:
        log.append("Erfolgreich. Offen bleibt der Slicer-Teil (der groessere Hebel): in Snapmaker Orca "
                   "unter Printer settings -> Extruder 1..4 -> Retraction 'Z hop type' von Auto auf Normal "
                   "stellen und als eigenes Preset speichern.")
    return "\n".join(log)


def tool_rollback(_args: dict) -> str:
    if CFG_PATH not in config_files():
        return f"config/{CFG_PATH} existiert nicht - nichts zurueckzunehmen."
    delete_config(CFG_PATH)
    state = firmware_restart_and_wait()
    after = printer_settings().get("max_z_accel") if state.get("state") == "ready" else None
    return (f"config/{CFG_PATH} geloescht, Klipper neu gestartet (Status: {state.get('state')}).\n"
            f"max_z_accel jetzt: {after}")


TOOLS = [
    {
        "name": "klipper_status",
        "description": ("Status des Snapmaker U1 lesen: Klipper-Zustand, laufender Druck, aktuelle "
                        "Z-Beschleunigung, Include-Reihenfolge und ob die Override-Datei vorhanden ist. "
                        "Rein lesend."),
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "handler": tool_status,
    },
    {
        "name": "klipper_list_config",
        "description": "Alle Klipper-Config-Dateien auf dem Drucker auflisten. Rein lesend.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "handler": tool_list_config,
    },
    {
        "name": "klipper_read_config",
        "description": "Inhalt einer Klipper-Config-Datei lesen, Standard printer.cfg. Rein lesend.",
        "inputSchema": {
            "type": "object",
            "properties": {"path": {"type": "string",
                                    "description": "Pfad relativ zum config-Root, z. B. printer.cfg"}},
            "additionalProperties": False,
        },
        "handler": tool_read_config,
    },
    {
        "name": "klipper_apply_z_accel",
        "description": ("Z-Beschleunigung (max_z_accel) senken, um das dumpfe Klack-Geraeusch der Z-Achse "
                        "zu reduzieren. Legt extended/klipper/z-noise-fix.cfg an, startet Klipper neu und "
                        "verifiziert das Ergebnis. Bricht ab, wenn ein Druck laeuft, und nimmt die "
                        "Aenderung automatisch zurueck, falls Klipper nicht sauber hochkommt. "
                        "printer.cfg wird nie veraendert."),
        "inputSchema": {
            "type": "object",
            "properties": {"accel": {"type": "number",
                                     "description": "Wert in mm/s^2, Standard 200 (Snapmaker-Empfehlung); "
                                                    "300-500 als Kompromiss bei vielen Z-Hops."}},
            "additionalProperties": False,
        },
        "handler": tool_apply,
    },
    {
        "name": "klipper_rollback_z_accel",
        "description": "Die Override-Datei extended/klipper/z-noise-fix.cfg loeschen und Klipper neu starten.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "handler": tool_rollback,
    },
]


# ------------------------------------------------------------ MCP over stdio

def handle(message: dict):
    method = message.get("method")
    msg_id = message.get("id")

    if method == "initialize":
        version = (message.get("params") or {}).get("protocolVersion") or PROTOCOL_FALLBACK
        return {"jsonrpc": "2.0", "id": msg_id, "result": {
            "protocolVersion": version,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        }}

    if method in ("notifications/initialized", "initialized", "notifications/cancelled"):
        return None

    if method == "ping":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {}}

    if method == "tools/list":
        tools = [{k: v for k, v in tool.items() if k != "handler"} for tool in TOOLS]
        return {"jsonrpc": "2.0", "id": msg_id, "result": {"tools": tools}}

    if method == "tools/call":
        params = message.get("params") or {}
        name = params.get("name")
        args = params.get("arguments") or {}
        tool = next((t for t in TOOLS if t["name"] == name), None)
        if tool is None:
            return {"jsonrpc": "2.0", "id": msg_id,
                    "error": {"code": -32602, "message": f"Unbekanntes Tool: {name}"}}
        try:
            text = tool["handler"](args)
            is_error = False
        except MoonrakerError as exc:
            text, is_error = str(exc), True
        except Exception as exc:  # noqa: BLE001 - Fehler als Toolergebnis zurueckgeben
            text, is_error = f"Unerwarteter Fehler: {type(exc).__name__}: {exc}", True
        return {"jsonrpc": "2.0", "id": msg_id,
                "result": {"content": [{"type": "text", "text": text}], "isError": is_error}}

    if msg_id is None:
        return None
    return {"jsonrpc": "2.0", "id": msg_id,
            "error": {"code": -32601, "message": f"Methode nicht unterstuetzt: {method}"}}


def main() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        response = handle(message)
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
