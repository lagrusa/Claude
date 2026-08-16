<#
    Snapmaker U1 (Paxx-Firmware): Z-Klopfen reduzieren, indem max_z_accel gesenkt wird.

    PowerShell-Variante von apply-z-noise-fix.sh - fuer Windows ohne bash/WSL.
    Muss auf einem Rechner im selben Netz wie der Drucker laufen.
    Laeuft mit Windows PowerShell 5.1 (Standard auf Windows) und mit PowerShell 7.
    Idempotent - mehrfaches Ausfuehren ist unschaedlich.

    Aufruf:
        powershell -ExecutionPolicy Bypass -File apply-z-noise-fix.ps1
        powershell -ExecutionPolicy Bypass -File apply-z-noise-fix.ps1 -Accel 300
        powershell -ExecutionPolicy Bypass -File apply-z-noise-fix.ps1 -Rollback
        powershell -ExecutionPolicy Bypass -File apply-z-noise-fix.ps1 -Printer 192.168.31.99 -ApiKey abc123
#>

param(
    [string]$Printer = "192.168.31.218",
    [double]$Accel = 200,
    [switch]$Rollback,
    [string]$ApiKey = $env:MOONRAKER_API_KEY
)

$ErrorActionPreference = "Stop"

$Api = "http://$Printer"
$CfgPath = "extended/klipper/z-noise-fix.cfg"
# Zahl immer mit Punkt als Dezimaltrenner in die Config schreiben, unabhaengig
# von der Windows-Regionseinstellung.
$AccelText = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0:0.##}", $Accel)

function Get-Headers {
    $h = @{}
    if ($ApiKey) { $h["X-Api-Key"] = $ApiKey }
    return $h
}

function Invoke-Moon {
    param(
        [string]$Method,
        [string]$Path,
        $Body = $null,
        [string]$ContentType = $null
    )
    $params = @{
        Uri             = "$Api$Path"
        Method          = $Method
        Headers         = (Get-Headers)
        TimeoutSec      = 25
        UseBasicParsing = $true
    }
    if ($null -ne $Body) { $params["Body"] = $Body }
    if ($ContentType) { $params["ContentType"] = $ContentType }
    try {
        return Invoke-RestMethod @params
    }
    catch {
        $code = $null
        if ($_.Exception.Response) {
            try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = $null }
        }
        if ($code -eq 401 -or $code -eq 403) {
            throw "HTTP $code von $Path. Moonraker verlangt offenbar einen API-Key: in Fluidd unter Settings -> API keys holen und mit -ApiKey <key> erneut starten."
        }
        throw "Zugriff auf $Api$Path fehlgeschlagen: $($_.Exception.Message)"
    }
}

function Step { param([string]$Text) Write-Host ""; Write-Host "== $Text" -ForegroundColor Cyan }
function Fail { param([string]$Text) Write-Host ""; Write-Host "FEHLER: $Text" -ForegroundColor Red; exit 1 }

function Get-PrinterState {
    $r = Invoke-Moon -Method GET -Path "/printer/info"
    return $r.result
}

function Get-PrintState {
    $r = Invoke-Moon -Method GET -Path "/printer/objects/query?print_stats"
    return $r.result.status.print_stats.state
}

function Get-PrinterSettings {
    $r = Invoke-Moon -Method GET -Path "/printer/objects/query?configfile=settings"
    return $r.result.status.configfile.settings.printer
}

function Get-ConfigFileList {
    $r = Invoke-Moon -Method GET -Path "/server/files/list?root=config"
    return @($r.result | ForEach-Object { $_.path })
}

function Send-ConfigFile {
    param([string]$RelPath, [string]$Content)

    $folder = ($RelPath -replace "\\", "/")
    $name = $folder.Substring($folder.LastIndexOf("/") + 1)
    $folder = if ($folder.Contains("/")) { $folder.Substring(0, $folder.LastIndexOf("/")) } else { "" }

    $boundary = "----psmoonraker" + [guid]::NewGuid().ToString("N")
    $LF = "`r`n"
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("--$boundary$LF")
    [void]$sb.Append("Content-Disposition: form-data; name=`"root`"$LF$LF" + "config$LF")
    if ($folder) {
        [void]$sb.Append("--$boundary$LF")
        [void]$sb.Append("Content-Disposition: form-data; name=`"path`"$LF$LF" + "$folder$LF")
    }
    [void]$sb.Append("--$boundary$LF")
    [void]$sb.Append("Content-Disposition: form-data; name=`"file`"; filename=`"$name`"$LF")
    [void]$sb.Append("Content-Type: application/octet-stream$LF$LF")
    [void]$sb.Append($Content)
    [void]$sb.Append($LF)
    [void]$sb.Append("--$boundary--$LF")

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    return Invoke-Moon -Method POST -Path "/server/files/upload" -Body $bytes `
        -ContentType "multipart/form-data; boundary=$boundary"
}

function Remove-OverrideFile {
    return Invoke-Moon -Method DELETE -Path "/server/files/config/$CfgPath"
}

function Restart-Klipper {
    param([int]$TimeoutSeconds = 75)
    Invoke-Moon -Method POST -Path "/printer/firmware_restart" | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $state = $null
    Start-Sleep -Seconds 3
    while ((Get-Date) -lt $deadline) {
        try { $state = Get-PrinterState } catch { $state = $null }
        Write-Host "." -NoNewline
        if ($state -and ($state.state -in @("ready", "error", "shutdown"))) { break }
        Start-Sleep -Seconds 3
    }
    Write-Host ""
    return $state
}

# ------------------------------------------------------------------ Schritt 1
Step "1/7 Drucker erreichbar?"
try { $info = Get-PrinterState }
catch {
    Fail ("$Api nicht erreichbar.`n" +
        "  - Laeuft dieser Rechner im selben WLAN wie der Drucker?`n" +
        "  - Ist am Touchscreen 'Einstellungen -> Wartung -> Advanced Mode' aktiv?`n" +
        "  - Stimmt die IP? Notfalls: powershell -File $($MyInvocation.MyCommand.Name) -Printer <ip>`n" +
        "  Details: $($_.Exception.Message)")
}
Write-Host "Klipper-Status: $($info.state)"
if ($info.state -ne "ready") { Write-Host "WARNUNG: Klipper ist nicht 'ready' - $($info.state_message)" -ForegroundColor Yellow }

# ------------------------------------------------------------------ Schritt 2
Step "2/7 Laeuft gerade ein Druck?"
$printState = Get-PrintState
Write-Host "Druckstatus: $printState"
if ($printState -in @("printing", "paused")) {
    Fail "Es laeuft ein Druck ($printState). Dieses Skript startet Klipper neu und wuerde ihn abbrechen. Bitte spaeter erneut ausfuehren."
}

# -------------------------------------------------------------------- Rollback
if ($Rollback) {
    Step "Rollback: $CfgPath loeschen"
    if ((Get-ConfigFileList) -notcontains $CfgPath) {
        Write-Host "config/$CfgPath existiert nicht - nichts zurueckzunehmen."
        exit 0
    }
    Remove-OverrideFile | Out-Null
    $state = Restart-Klipper
    Write-Host "Geloescht, Klipper neu gestartet (Status: $($state.state))."
    Write-Host "max_z_accel jetzt: $((Get-PrinterSettings).max_z_accel)"
    exit 0
}

# ------------------------------------------------------------------ Schritt 3
Step "3/7 Aktuellen Wert lesen"
$before = (Get-PrinterSettings).max_z_accel
Write-Host "max_z_accel vorher: $before"

# ------------------------------------------------------------------ Schritt 4
Step "4/7 Include-Reihenfolge in printer.cfg pruefen"
$cfg = Invoke-Moon -Method GET -Path "/server/files/config/printer.cfg"
$lines = ($cfg -split "`n")
$printerLine = $null
$includeLine = $null
for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i].Trim()
    if ($line.StartsWith("[printer]") -and -not $printerLine) { $printerLine = $i + 1 }
    if ($line.StartsWith("[include") -and $line -match "extended") { $includeLine = $i + 1 }
}
Write-Host "[printer] in Zeile $printerLine, extended-Include in Zeile $includeLine"
if (-not $includeLine) {
    Fail "Kein Include fuer extended/klipper in printer.cfg gefunden. Ohne diesen Include wird die Override-Datei nicht geladen (ist wirklich die Paxx-Firmware installiert?)."
}
if ($printerLine -and $includeLine -lt $printerLine) {
    Fail "Der extended-Include steht VOR dem [printer]-Block. Ein Override greift so nicht - der Wert muesste direkt in printer.cfg geaendert werden (geht bei jedem Firmware-Update verloren). Dieses Skript aendert printer.cfg absichtlich nicht."
}

# ------------------------------------------------------------------ Schritt 5
Step "5/7 Override-Datei hochladen"
$content = @"
# Z-Klopfen reduzieren (Snapmaker-Empfehlung: 200 mm/s^2)
# Angelegt von apply-z-noise-fix.ps1
[printer]
max_z_accel: $AccelText

# Marker, um zu pruefen, ob diese Datei geladen wird.
# Bewusst action_respond_info statt RESPOND/M118 - die brauchen ein [respond]-Modul.
[gcode_macro Z_NOISE_FIX_CHECK]
gcode:
    {action_respond_info("z-noise-fix.cfg ist aktiv, max_z_accel=$AccelText")}
"@

Send-ConfigFile -RelPath $CfgPath -Content $content | Out-Null
if ((Get-ConfigFileList) -notcontains $CfgPath) {
    Fail "Upload hat die Datei nicht an der erwarteten Stelle abgelegt (config/$CfgPath). Es wurde kein Neustart ausgeloest."
}
Write-Host "Hochgeladen nach config/$CfgPath"

# ------------------------------------------------------------------ Schritt 6
Step "6/7 Klipper neu starten"
$state = Restart-Klipper
Write-Host "Status: $($state.state)"
if ($state.state -ne "ready") {
    Write-Host "Klipper meldet: $($state.state_message)" -ForegroundColor Yellow
    Write-Host "Nehme die Aenderung automatisch zurueck..."
    Remove-OverrideFile | Out-Null
    Restart-Klipper | Out-Null
    Fail "Config wurde zurueckgenommen, Klipper neu gestartet. Bitte die Meldung oben melden."
}

# ------------------------------------------------------------------ Schritt 7
Step "7/7 Verifizieren"
$after = (Get-PrinterSettings).max_z_accel
$objects = (Invoke-Moon -Method GET -Path "/printer/objects/list").result.objects
$marker = [bool]($objects | Where-Object { $_ -match "Z_NOISE_FIX_CHECK" })

Write-Host ""
Write-Host "-------------------------------------------"
Write-Host "max_z_accel:   $before  ->  $after"
Write-Host "Marker-Makro:  $(if ($marker) { 'ja' } else { 'nein' })"
Write-Host "Config-Datei:  config/$CfgPath"
Write-Host "-------------------------------------------"

if (-not $marker) {
    Fail "Die Datei wird nicht geladen. Pfad in Fluidd unter Configuration pruefen (config/$CfgPath)."
}
if ($null -eq $after -or [math]::Abs([double]$after - $Accel) -gt 0.01) {
    Fail "Datei wird geladen, aber max_z_accel ist noch $after. Vermutlich Include-Reihenfolge - siehe claude-code-runbook-klack-fix.md, Schritt 4."
}

Write-Host ""
Write-Host "Fertig." -ForegroundColor Green
Write-Host "Noch offen (GUI, nicht automatisierbar) - und der groessere Hebel:"
Write-Host "  Snapmaker Orca -> Printer settings -> Extruder 1..4 -> Retraction"
Write-Host "  -> 'Z hop type' von Auto auf Normal, danach als eigenes Preset speichern."
