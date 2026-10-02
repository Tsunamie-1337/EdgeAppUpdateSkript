#Requires -Version 7.0
<#
.SYNOPSIS
    IEM-AppInstaller V6 - App management on Siemens Industrial Edge via iectl.
    IEM-AppInstaller V6 - App-Verwaltung auf Siemens Industrial Edge via iectl.

.DESCRIPTION
    One script for both IEM APIs. The API is chosen via -ApiVersion
    (V1 = "iectl iem ...", V2 = "iectl iem-v2 ..."); without a parameter the
    script asks interactively. All iectl calls go through one adapter layer
    (New-ApiProfile), so the eventual removal of the V1 API only needs to be
    done in one place.

    Flow:
      Config -> Mode -> App -> Version/Action -> Devices -> Confirmation
      -> Execution -> Verification -> back to Mode

    Navigation runs through a state machine in the same process. 'q' always
    goes back exactly one step. The script never restarts itself.

    ---

    Ein Skript fuer beide IEM-APIs. Die API wird ueber -ApiVersion gewaehlt
    (V1 = "iectl iem ...", V2 = "iectl iem-v2 ..."); ohne Parameter fragt das
    Skript interaktiv. Saemtliche iectl-Aufrufe laufen ueber eine Adapter-
    Schicht (New-ApiProfile), sodass die kommende Abloesung der V1-API nur
    dort nachgezogen werden muss.

    Ablauf:
      Konfiguration -> Modus -> App -> Version/Aktion -> Geraete -> Bestaetigung
      -> Ausfuehrung -> Verifikation -> zurueck zum Modus

    Navigation erfolgt ueber eine State-Machine im selben Prozess. 'q' geht
    immer genau einen Schritt zurueck. Das Skript startet sich nie selbst neu.

.PARAMETER ApiVersion
    V1 (iectl iem) or V2 (iectl iem-v2). Without it: interactive prompt.
    V1 (iectl iem) oder V2 (iectl iem-v2). Ohne Angabe: interaktive Abfrage.

.EXAMPLE
    pwsh -File .\EN-IEM-AppInstaller.ps1 -ApiVersion V1

.NOTES
    Requirement: iectl in PATH, PowerShell 7 (pwsh).
    Voraussetzung: iectl im PATH, PowerShell 7 (pwsh).
#>

[CmdletBinding()]
param(
    [ValidateSet('V1', 'V2')]
    [string]$ApiVersion,

    # Maximale Anzahl Device-IDs pro batch-create-Auftrag.
    [ValidateRange(1, 100)]
    [int]$BatchSize = 10,

    # Gleichzeitig laufende iectl-Prozesse (Heartbeat-Scan und Job-Waits).
    [ValidateRange(1, 20)]
    [int]$MaxParallel = 5,

    # Timeout je device-job-wait-Aufruf in Sekunden.
    [int]$JobWaitTimeoutSec = 120,

    # Wie oft device-job-wait bei Status 'timeout' erneut aufgerufen wird,
    # bevor der Job als nicht abgeschlossen gemeldet wird (siehe Wait-DeviceJobs).
    # Live beobachtet: manche Jobs (v.a. Erstinstallationen mit Image-Pull)
    # brauchen laenger als ein einzelnes 120s-Fenster.
    [ValidateRange(1, 10)]
    [int]$JobWaitMaxAttempts = 3,

    # Heartbeat juenger als das -> ONLINE.
    [int]$OnlineMaxAgeMin = 30,

    # Heartbeat aelter als das -> OFFLINE. Dazwischen -> UNBEKANNT.
    [int]$OfflineMinAgeMin = 60,

    # Preflight-Pruefung der API-Endpunkte ueberspringen.
    [switch]$SkipPreflight
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Skript-Status
# ─────────────────────────────────────────────────────────────────────────────

$script:ScriptVersion      = 'V6'
$script:ScriptName         = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
$script:LogFile            = $null
$script:Api                = $null
$script:BatchSize          = $BatchSize
$script:MaxParallel        = $MaxParallel
$script:JobWaitTimeoutSec  = $JobWaitTimeoutSec
$script:JobWaitMaxAttempts = $JobWaitMaxAttempts
$script:OnlineMaxAgeMin    = $OnlineMaxAgeMin
$script:OfflineMinAgeMin   = $OfflineMinAgeMin
$script:FirmwareReleaseCache = @{}   # DeviceTypeId -> Get-FirmwareReleases-Ergebnis, siehe dort

# Workflow-Zustand zwischen den States
$script:ConfigName      = $null
$script:AppCatalog      = @()
$script:SelectedApp     = $null
$script:SelectedVersion = $null
$script:AppVersions     = @()
$script:DeviceRows      = @()
$script:TargetDevices   = @()
$script:Operation       = $null
$script:LastQPressed    = $false

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Logging
# ─────────────────────────────────────────────────────────────────────────────

function Initialize-Log {
    $logDir = Join-Path $PSScriptRoot 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

    $timestamp      = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $script:LogFile = Join-Path $logDir "$($script:ScriptName)_${timestamp}_$($script:ScriptVersion).log"

    @"
================================================================================
  IEM App Installer - Log
  Script version: $($script:ScriptVersion)
  API version:    $($script:Api.Version)  ($($script:Api.Root))
  Started:        $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  User:           $env:USERNAME
  Machine:        $env:COMPUTERNAME
  PowerShell:                     $($PSVersionTable.PSVersion)
================================================================================

"@ | Out-File -FilePath $script:LogFile -Encoding UTF8

    Write-Host "  Log file: $script:LogFile" -ForegroundColor DarkGray
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'STEP', 'OK', 'WARN', 'ERROR', 'CMD', 'DATA', 'SEP')][string]$Level = 'INFO'
    )
    $prefix = switch ($Level) {
        'INFO'  { '[INFO ]' }
        'STEP'  { '[STEP ]' }
        'OK'    { '[OK   ]' }
        'WARN'  { '[WARN ]' }
        'ERROR' { '[ERROR]' }
        'CMD'   { '[CMD  ]' }
        'DATA'  { '[DATA ]' }
        'SEP'   { '[-----]' }
    }
    if ($script:LogFile) {
        "$(Get-Date -Format 'HH:mm:ss') $prefix $Message" |
            Out-File -FilePath $script:LogFile -Append -Encoding UTF8
    }
}

function Write-LogSeparator {
    param([string]$Title = '')
    $sep = if ($Title) { "--- $Title " + ('-' * [Math]::Max(0, 60 - $Title.Length)) } else { '-' * 70 }
    Write-Log -Message $sep -Level 'SEP'
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Konsolenausgabe (schreibt zugleich ins Log)
# ─────────────────────────────────────────────────────────────────────────────

function Write-Header {
    param([string]$Text)
    $line = '=' * 70
    Write-Host ''
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
    Write-Host ''
    Write-Log -Message ('=' * 60) -Level 'SEP'
    Write-Log -Message "  $Text"   -Level 'SEP'
    Write-Log -Message ('=' * 60) -Level 'SEP'
}

function Write-Step    { param([string]$Text) Write-Host "[>] $Text" -ForegroundColor Yellow;  Write-Log $Text 'STEP' }
function Write-Success { param([string]$Text) Write-Host "[OK] $Text" -ForegroundColor Green;  Write-Log $Text 'OK'   }
function Write-Warn    { param([string]$Text) Write-Host "[!]  $Text" -ForegroundColor Magenta; Write-Log $Text 'WARN' }
function Write-Err     { param([string]$Text) Write-Host "[X]  $Text" -ForegroundColor Red;    Write-Log $Text 'ERROR' }

function Write-Info {
    param([string]$Text, [System.ConsoleColor]$Color = 'Gray')
    Write-Host "     $Text" -ForegroundColor $Color
    Write-Log $Text 'INFO'
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: iectl-Wrapper
# ─────────────────────────────────────────────────────────────────────────────

function Get-IectlErrorText {
    <# Zieht die eigentliche Fehlerzeile aus der iectl-Ausgabe und wirft den
       angehaengten Usage-/Flag-Block weg, der sonst die Konsole flutet. #>
    param([string]$StdErr, [string]$StdOut, [int]$ExitCode)

    foreach ($stream in @($StdErr, $StdOut)) {
        if (-not $stream) { continue }
        $errLine = ($stream -split "`r?`n" | Where-Object { $_ -match '^\s*Error:' } | Select-Object -First 1)
        if ($errLine) { return $errLine.Trim() }
    }
    # Kein "Error:"-Praefix: strukturierte API-Fehler auswerten.
    foreach ($stream in @($StdOut, $StdErr)) {
        if (-not $stream) { continue }
        try {
            $j = $stream | ConvertFrom-Json -ErrorAction Stop
            if ($j.errors) {
                return (@($j.errors | ForEach-Object { "$($_.message) (Code $($_.errorCode)$($_.status))" }) -join '; ')
            }
        } catch { }
    }
    return "ExitCode $ExitCode (no evaluable error message)"
}

function Invoke-Iectl {
    <#
    .SYNOPSIS
        Fuehrt iectl als Prozess aus. Argumente gehen als Array direkt an den
        Prozess - kein Shell-Parsing, kein Quoting-Problem.
    .NOTES
        stdout und stderr werden ASYNCHRON gelesen. iectl haengt bei Fehlern
        den kompletten Hilfetext an stderr; wuerde man erst stdout komplett
        lesen, koennte der stderr-Puffer volllaufen und den Prozess blockieren.
    #>
    param(
        [Parameter(Mandatory)][string[]]$CmdArgs,
        [switch]$Raw,
        [switch]$AllowFailure,
        [int]$TimeoutSec = 180
    )

    Write-Log "Ausfuehren: iectl $($CmdArgs -join ' ')" 'CMD'

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = 'iectl'
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    foreach ($a in $CmdArgs) { $psi.ArgumentList.Add([string]$a) }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    try {
        [void]$proc.Start()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()

        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill($true) } catch { }
            $msg = "iectl timeout after ${TimeoutSec}s: iectl $($CmdArgs -join ' ')"
            Write-Log $msg 'ERROR'
            if ($AllowFailure) { return [pscustomobject]@{ Success = $false; Error = $msg; Data = $null } }
            throw $msg
        }

        $stdout   = $outTask.GetAwaiter().GetResult()
        $stderr   = $errTask.GetAwaiter().GetResult()
        $exitCode = $proc.ExitCode

        Write-Log "ExitCode: $exitCode" 'CMD'
        if ($stdout) { Write-Log "Antwort: $($stdout.Trim())" 'DATA' }
        if ($stderr) { Write-Log "STDERR: $($stderr.Trim())"  'DATA' }

        if ($exitCode -ne 0) {
            $msg = Get-IectlErrorText -StdErr $stderr -StdOut $stdout -ExitCode $exitCode
            if ($AllowFailure) { return [pscustomobject]@{ Success = $false; Error = $msg; Data = $null } }
            throw $msg
        }

        $stdout = $stdout.Trim()
        $value  = if ($Raw) { $stdout }
                  elseif ([string]::IsNullOrWhiteSpace($stdout)) { $null }
                  else { try { $stdout | ConvertFrom-Json } catch { $stdout } }

        if ($AllowFailure) { return [pscustomobject]@{ Success = $true; Error = $null; Data = $value } }
        return $value
    }
    finally {
        $proc.Dispose()
    }
}

function Get-DataArray {
    <# Normalisiert die unterschiedlichen Huellen der IEM-Antworten auf ein Array. #>
    param($Response)
    if ($null -eq $Response)   { return @() }
    if ($Response -is [array]) { return @($Response) }
    foreach ($prop in 'data', 'content', 'items', 'jobs', 'devices') {
        if ($Response.PSObject.Properties[$prop]) {
            $v = $Response.$prop
            if ($null -eq $v) { return @() }
            return @($v)
        }
    }
    return @($Response)
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: API-Adapter
#
# Einziger Ort, an dem konkrete iectl-Befehle stehen. Wird die V1-API
# abgeschaltet, faellt hier genau ein Block weg - der restliche Code bleibt
# unveraendert.
# ─────────────────────────────────────────────────────────────────────────────

function New-ApiProfile {
    param([Parameter(Mandatory)][ValidateSet('V1', 'V2')][string]$Version)

    if ($Version -eq 'V1') {
        return @{
            Version = 'V1'
            Root    = 'iectl iem'
            # Woher kommen die installierten App-Versionen je Geraet?
            #   ListApps = ein einziger "device list-apps"-Aufruf fuer alle Geraete
            InventorySource = 'ListApps'
            Ops = @{
                'device.list'       = { param($p) @('iem', 'device', 'list', '--page', "$($p.Page)", '--size', "$($p.Size)") }
                'device.details'    = { param($p) @('iem', 'device', 'get-details', '--id', $p.DeviceId) }
                'device.statistics' = { param($p) @('iem', 'device', 'get-statistics', '--id', $p.DeviceId) }
                'device.apps.all'   = { param($p) @('iem', 'device', 'list-apps') }
                'device.apps.one'   = { param($p) @('iem', 'device', 'list-apps', '--deviceid', $p.DeviceId) }
                'catalog.list'      = { param($p) @('iem', 'device-apps', 'list', '--show-all') }
                'catalog.details'   = { param($p) @('iem', 'device-apps', 'app-details', '--app-id', $p.AppId) }
                'job.batchStatus'   = { param($p) @('iem', 'job', 'batch-status', '--batchId', $p.BatchId) }
                'job.batchJobs'     = { param($p) @('iem', 'job', 'list', '--id', $p.BatchId) }
                'job.deviceJobList' = { param($p) @('iem', 'job', 'device-job-list', '--page', "$($p.Page)", '--pagesize', "$($p.Size)") }
                'job.wait'          = { param($p) @('iem', 'job', 'device-job-wait', '--id', $p.JobId, '--timeout', "$($p.TimeoutSec)") }
                'job.status'        = { param($p) @('iem', 'job', 'status', '--id', $p.JobId) }
                'firmware.list'     = { param($p) @('iem', 'device', 'firmware', 'list', '--deviceid', $p.DeviceId) }
                # --releaseid (nicht --firmwareid!) - siehe --help. Wird bei
                # Weglassen zur "neuesten kompatiblen Version" - genau das
                # wollen wir NICHT (siehe Get-FirmwareReleases/Resolve-NextFirmwareStep),
                # daher immer explizit angeben.
                'firmware.update'   = { param($p) @('iem', 'device', 'firmware', 'update', '--deviceid', $p.DeviceId, '--releaseid', $p.ReleaseId) }
                'firmware.status'   = { param($p) @('iem', 'device', 'firmware', 'update-status', '--deviceid', $p.DeviceId) }
                'token.fetch'       = { param($p) @('iem', 'token', 'fetch') }
                'job.batchCreate'   = {
                    param($p)
                    $a = @('iem', 'job', 'batch-create', '--appid', $p.AppId, '--operation', $p.Operation, '--infoMap', $p.InfoMap)
                    if ($p.VersionId) { $a += @('--versionId', $p.VersionId) }
                    # KEIN ', $a' hier: das wuerde das Array beim spaeteren
                    # [string[]]@(...)-Cast in Get-ApiArgs zu einem einzigen
                    # zusammengefuegten String kollabieren lassen, statt es als
                    # einzelne Argumente zu entrollen (live verifizierter Bug -
                    # iectl erhielt die komplette Befehlszeile als EIN Argument
                    # und meldete "unknown command"). $a als letzter Ausdruck
                    # entrollt korrekt in einzelne Pipeline-Objekte.
                    $a
                }
            }
            # Endpunkte, die der App-Workflow zwingend braucht.
            Probes = @(
                @{ Name = 'device list';       Op = 'device.list';    P = @{ Page = 1; Size = 1 } }
                @{ Name = 'device-apps list';  Op = 'catalog.list';   P = @{} }
                @{ Name = 'device list-apps';  Op = 'device.apps.all'; P = @{} }
            )
        }
    }

    return @{
        Version = 'V2'
        Root    = 'iectl iem-v2'
        # V2 kennt KEIN eigenes "device list-apps", braucht es aber auch nicht:
        # "device list" liefert je Geraet bereits ein "installedApplications"-
        # Array (id/name/version) sowie ein echtes "status"-Feld (Online/
        # Offline) mit - beides in einem einzigen Aufruf. Siehe Get-DeviceInventory
        # und Get-DeviceLiveState.
        InventorySource = 'Embedded'
        Ops = @{
            'device.list'       = { param($p) @('iem-v2', 'device', 'list', '--page', "$($p.Page)", '--size', "$($p.Size)") }
            'device.details'    = { param($p) @('iem-v2', 'device', 'details', '--device-id', $p.DeviceId) }
            'device.statistics' = { param($p) @('iem-v2', 'device', 'statistics', '--id', $p.DeviceId) }
            'device.apps.all'   = $null   # existiert in V2 nicht
            'device.apps.one'   = $null   # existiert in V2 nicht
            'catalog.list'      = { param($p) @('iem-v2', 'device-apps', 'list') }
            'catalog.details'   = { param($p) @('iem-v2', 'device-apps', 'details', '--applicationId', $p.AppId) }
            'job.batchStatus'   = { param($p) @('iem-v2', 'job', 'batch-status', '--batchId', $p.BatchId) }
            'job.batchJobs'     = { param($p) @('iem-v2', 'job', 'get-batch-jobs', '--id', $p.BatchId) }
            'job.deviceJobList' = { param($p) @('iem-v2', 'job', 'device-job-list', '--page', "$($p.Page)", '--pagesize', "$($p.Size)") }
            'job.wait'          = { param($p) @('iem-v2', 'job', 'device-job-wait', '--id', $p.JobId, '--timeout', "$($p.TimeoutSec)") }
            'job.status'        = { param($p) @('iem-v2', 'job', 'install-job-status', '--id', $p.JobId) }
            'firmware.list'     = { param($p) @('iem-v2', 'device', 'firmware', 'list', '--deviceid', $p.DeviceId) }
            'firmware.update'   = { param($p) @('iem-v2', 'device', 'firmware', 'update', '--deviceid', $p.DeviceId, '--releaseid', $p.ReleaseId) }
            'firmware.status'   = { param($p) @('iem-v2', 'device', 'firmware', 'update-status', '--deviceid', $p.DeviceId) }
            'token.fetch'       = { param($p) @('iem-v2', 'token', 'fetch') }
            'job.batchCreate'   = {
                param($p)
                $a = @('iem-v2', 'job', 'batch-create', '--appid', $p.AppId, '--operation', $p.Operation, '--infoMap', $p.InfoMap)
                if ($p.VersionId) { $a += @('--versionId', $p.VersionId) }
                # KEIN ', $a' - siehe Kommentar bei der V1-Variante weiter oben.
                $a
            }
        }
        Probes = @(
            @{ Name = 'device list';           Op = 'device.list';       P = @{ Page = 1; Size = 1 } }
            @{ Name = 'device-apps list';      Op = 'catalog.list';      P = @{} }
            @{ Name = 'job device-job-list';   Op = 'job.deviceJobList'; P = @{ Page = 1; Size = 1 } }
        )
    }
}

function Test-ApiOp {
    param([Parameter(Mandatory)][string]$Op)
    return ($null -ne $script:Api.Ops[$Op])
}

function Get-ApiArgs {
    param(
        [Parameter(Mandatory)][string]$Op,
        [hashtable]$P = @{}
    )
    $builder = $script:Api.Ops[$Op]
    if ($null -eq $builder) {
        throw "Operation '$Op' is not available in the $($script:Api.Version) API."
    }
    return [string[]]@(& $builder $P)
}

function Invoke-Api {
    param(
        [Parameter(Mandatory)][string]$Op,
        [hashtable]$P = @{},
        [switch]$AllowFailure,
        [int]$TimeoutSec = 180
    )
    $cmdArgs = Get-ApiArgs -Op $Op -P $P
    return Invoke-Iectl -CmdArgs $cmdArgs -AllowFailure:$AllowFailure -TimeoutSec $TimeoutSec
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Preflight
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-Preflight {
    <#
        Prueft die vom App-Workflow benoetigten Endpunkte und gibt eine
        kompakte Tabelle aus - bewusst KEIN Roh-JSON auf der Konsole, die
        Rohantworten landen nur im Log.
        Rueckgabe: $true = weitermachen, $false = abbrechen.
    #>
    Write-Header "Preflight - $($script:Api.Root)"
    Write-LogSeparator 'Preflight'

    $results = foreach ($probe in $script:Api.Probes) {
        Write-Host ("  {0,-24} " -f $probe.Name) -NoNewline -ForegroundColor Gray
        if (-not (Test-ApiOp $probe.Op)) {
            Write-Host '[MISSING]  not available in this API' -ForegroundColor Red
            [pscustomobject]@{ Name = $probe.Name; Ok = $false; Detail = 'Operation not available in this API' }
            continue
        }
        $r = Invoke-Api -Op $probe.Op -P $probe.P -AllowFailure -TimeoutSec 60
        if ($r.Success) {
            Write-Host '[OK]' -ForegroundColor Green
            [pscustomobject]@{ Name = $probe.Name; Ok = $true; Detail = 'reachable' }
        }
        else {
            Write-Host "[ERROR] $($r.Error)" -ForegroundColor Red
            [pscustomobject]@{ Name = $probe.Name; Ok = $false; Detail = $r.Error }
        }
    }

    foreach ($r in $results) {
        Write-Log ("Preflight {0,-24} {1}  {2}" -f $r.Name, $(if ($r.Ok) { 'OK' } else { 'FEHLER' }), $r.Detail) 'INFO'
    }

    $failed = @($results | Where-Object { -not $_.Ok })
    Write-Host ''
    if ($failed.Count -eq 0) {
        Write-Success "All $($results.Count) required $($script:Api.Version) endpoints are reachable."
        return $true
    }

    Write-Warn "$($failed.Count) of $($results.Count) endpoint(s) not available:"
    foreach ($f in $failed) { Write-Info "- $($f.Name): $($f.Detail)" -Color Red }
    Write-Host ''
    Write-Info 'The workflow will fail at these points.' -Color Yellow
    if ($script:Api.Version -eq 'V2') {
        Write-Info 'On IEM instances without a complete v2 API, -ApiVersion V1 is the working option.' -Color Yellow
    }
    Write-Host ''
    $answer = (Read-Host 'Continue anyway? [y/N]').Trim()
    Write-Log "Preflight-Fortsetzung: '$answer'" 'INFO'
    return ($answer -match '^[jJyY]')
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Versionsvergleich
# ─────────────────────────────────────────────────────────────────────────────

function ConvertTo-SemVerParts {
    param([string]$Version)
    $m = [regex]::Match([string]$Version, '^\s*v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?')
    if (-not $m.Success) { return @(0, 0, 0, 0) }
    return @(
        [int]$m.Groups[1].Value
        $(if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { 0 })
        $(if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { 0 })
        $(if ($m.Groups[4].Success) { [int]$m.Groups[4].Value } else { 0 })
    )
}

function Compare-SemVer {
    <# -1 = A aelter, 0 = gleich, 1 = A neuer. Semantisch, nicht alphabetisch:
       1.10.0 gilt korrekt als neuer als 1.9.0. #>
    param([string]$A, [string]$B)
    $x = ConvertTo-SemVerParts $A
    $y = ConvertTo-SemVerParts $B
    for ($i = 0; $i -lt 4; $i++) {
        if ($x[$i] -gt $y[$i]) { return 1 }
        if ($x[$i] -lt $y[$i]) { return -1 }
    }
    return 0
}

function Test-IsRealVersion {
    param([string]$Version)
    return ($Version -and $Version -notmatch '^\(' -and $Version -ne 'unknown' -and $Version -ne 'unbekannt' -and $Version -ne 'error' -and $Version -ne 'Fehler')
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Auswahl-UI
# ─────────────────────────────────────────────────────────────────────────────

function Select-FromList {
    <# Nummerierte Einfachauswahl. Rueckgabe $null = 'q' (einen Schritt zurueck). #>
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][string]$DisplayProperty,
        [string]$Prompt = "Choice (number, q = back)"
    )
    if ($Items.Count -eq 0) {
        Write-Warn 'No entries available.'
        return $null
    }

    while ($true) {
        for ($i = 0; $i -lt $Items.Count; $i++) {
            Write-Host ("  [{0,3}]  {1}" -f ($i + 1), $Items[$i].$DisplayProperty)
        }
        Write-Host ''

        $userInput = (Read-Host $Prompt).Trim()
        Write-Log "Benutzereingabe: '$userInput'" 'INFO'

        if ($userInput -match '^[qQ]$') { return $null }
        if ($userInput -match '^\d+$') {
            $n = [int]$userInput
            if ($n -ge 1 -and $n -le $Items.Count) { return $Items[$n - 1] }
        }
        Write-Warn "Invalid input. Please enter 1 to $($Items.Count) or q."
    }
}

function Select-DevicesCheckbox {
    <#
        Pfeiltasten navigieren, Space waehlt, A alle, N keine, O schaltet
        Offline-/Unbekannt-Geraete frei, Enter bestaetigt, Q geht zurueck.

        Geraete, die nicht sicher online sind (RequiresOfflineUnlock), sind
        PER DEFAULT gesperrt - man kann weder mit dem Cursor auf sie
        springen noch sie mit Space waehlen, genau wie andere gesperrte
        Eintraege (z.B. "bereits aktuell"). Erst die 'O'-Taste schaltet sie
        fuer diese Checkbox-Sitzung frei: danach sind sie ganz normal
        navigierbar/waehlbar, nur farblich (Gelb) markiert. Damit ist die
        Entscheidung "auch offline einplanen" ein bewusster Schritt AN DER
        AUSWAHL selbst, statt einer spaeten Ja/Nein-Rueckfrage nach der
        eigentlichen Bestaetigung.

        Rueckgabe: $null bei Q, sonst Array der gewaehlten Eintraege.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [string]$Title = 'Select devices'
    )
    if ($Items.Count -eq 0) {
        Write-Warn 'No devices available.'
        return @()
    }

    $selected       = [bool[]]::new($Items.Count)
    $offlineUnlocked = $false

    function Test-EffectiveLocked {
        param($Item, [bool]$OfflineUnlocked)
        return ($Item.IsLocked -or ($Item.RequiresOfflineUnlock -and -not $OfflineUnlocked))
    }

    $cursor = 0
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if (-not (Test-EffectiveLocked $Items[$i] $offlineUnlocked)) { $cursor = $i; break }
    }

    while ($true) {
        $anySelectable = @($Items | Where-Object { -not (Test-EffectiveLocked $_ $offlineUnlocked) }).Count -gt 0

        Clear-Host
        Write-Host ''
        Write-Host "  $Title" -ForegroundColor White
        Write-Host '  Arrows navigate | Space select | A all | N none | O unlock offline/unknown | Enter confirm | Q back' -ForegroundColor DarkGray
        if ($offlineUnlocked) {
            Write-Host '  Offline/unknown devices: UNLOCKED - actions on them only run once reconnected.' -ForegroundColor DarkYellow
        }
        else {
            Write-Host '  Offline/unknown devices: locked (default) - press [O] to make them selectable.' -ForegroundColor DarkGray
        }
        Write-Host ('  ' + ('-' * 108)) -ForegroundColor DarkGray
        Write-Host ''

        for ($i = 0; $i -lt $Items.Count; $i++) {
            $item        = $Items[$i]
            $isCursor    = ($i -eq $cursor)
            $prefix      = if ($isCursor) { '> ' } else { '  ' }
            $effLocked   = Test-EffectiveLocked $item $offlineUnlocked

            if ($item.IsLocked) {
                # Harte Sperre - unabhaengig vom Offline-Toggle.
                $line  = "  $prefix[ ]  {0,-22} | {1,-26} | {2}" -f $item.DeviceName, $item.StatusText, $item.LockReason
                $color = if ($item.IsUpToDate) { 'Green' } else { 'DarkGray' }
            }
            elseif ($effLocked) {
                # Weiche Sperre: offline/unbekannt, noch nicht freigeschaltet.
                $line  = "  $prefix[ ]  {0,-22} | {1,-26} | {2}" -f $item.DeviceName, $item.StatusText, '[O] to unlock'
                $color = 'DarkGray'
            }
            else {
                $box   = if ($selected[$i]) { '[x]' } else { '[ ]' }
                $action = if ($item.RequiresOfflineUnlock) { "$($item.ActionText)  (queued until reconnect)" } else { $item.ActionText }
                $line  = "  $prefix$box  {0,-22} | {1,-26} | {2}" -f $item.DeviceName, $item.StatusText, $action
                $color = if ($item.RequiresOfflineUnlock) { 'Yellow' }
                         elseif ($item.IsDowngrade)        { 'DarkYellow' }
                         else                              { 'White' }
            }

            if ($isCursor) { Write-Host $line -ForegroundColor $color -BackgroundColor DarkBlue }
            else           { Write-Host $line -ForegroundColor $color }
        }

        $selCount   = @($selected | Where-Object { $_ }).Count
        $selOffline = 0
        for ($i = 0; $i -lt $Items.Count; $i++) {
            if ($selected[$i] -and $Items[$i].RequiresOfflineUnlock) { $selOffline++ }
        }
        Write-Host ''
        Write-Host "  $selCount device(s) selected." -ForegroundColor Cyan -NoNewline
        if ($selOffline -gt 0) { Write-Host "  ($selOffline of these offline/unknown - queued)" -ForegroundColor Yellow } else { Write-Host '' }
        Write-Host ''

        $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

        switch ($key.VirtualKeyCode) {
            38 {  # hoch
                if ($anySelectable) {
                    do { $cursor = if ($cursor -gt 0) { $cursor - 1 } else { $Items.Count - 1 } }
                    while (Test-EffectiveLocked $Items[$cursor] $offlineUnlocked)
                }
            }
            40 {  # runter
                if ($anySelectable) {
                    do { $cursor = if ($cursor -lt ($Items.Count - 1)) { $cursor + 1 } else { 0 } }
                    while (Test-EffectiveLocked $Items[$cursor] $offlineUnlocked)
                }
            }
            32 { if (-not (Test-EffectiveLocked $Items[$cursor] $offlineUnlocked)) { $selected[$cursor] = -not $selected[$cursor] } }
            65 { for ($i = 0; $i -lt $Items.Count; $i++) { if (-not (Test-EffectiveLocked $Items[$i] $offlineUnlocked)) { $selected[$i] = $true } } }
            78 { for ($i = 0; $i -lt $Items.Count; $i++) { $selected[$i] = $false } }
            79 {  # O - Offline-/Unbekannt-Geraete freischalten/sperren
                $offlineUnlocked = -not $offlineUnlocked
                Write-Log "Offline-Freischaltung ('O') umgeschaltet: $(if ($offlineUnlocked) { 'FREIGESCHALTET' } else { 'gesperrt' })" 'INFO'
                if (-not $offlineUnlocked) {
                    # Beim erneuten Sperren: Auswahl auf jetzt wieder
                    # gesperrten Geraeten aufheben, sonst zaehlt ein
                    # "unsichtbar" gesperrtes Geraet weiter mit.
                    for ($i = 0; $i -lt $Items.Count; $i++) {
                        if ($Items[$i].RequiresOfflineUnlock -and -not $Items[$i].IsLocked) { $selected[$i] = $false }
                    }
                    if (Test-EffectiveLocked $Items[$cursor] $offlineUnlocked) {
                        for ($i = 0; $i -lt $Items.Count; $i++) {
                            if (-not (Test-EffectiveLocked $Items[$i] $offlineUnlocked)) { $cursor = $i; break }
                        }
                    }
                }
            }
            13 {
                $result = @()
                for ($i = 0; $i -lt $Items.Count; $i++) { if ($selected[$i]) { $result += $Items[$i] } }
                Write-Log "Geraeteauswahl bestaetigt (Enter): $($result.Count) Geraet(e) - $(($result | ForEach-Object { $_.DeviceName }) -join ', ')" 'INFO'
                Clear-Host
                return $result
            }
            81 {
                Write-Log "Geraeteauswahl abgebrochen (Q) - $selCount Geraet(e) waren zu diesem Zeitpunkt ausgewaehlt." 'INFO'
                Clear-Host
                return $null
            }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Geraetedaten
# ─────────────────────────────────────────────────────────────────────────────

function Get-AllDevices {
    <# Laedt alle Geraete ueber alle Seiten. #>
    $pageSize = 200
    $page     = 1
    $all      = @()

    while ($page -le 100) {
        $resp  = Invoke-Api -Op 'device.list' -P @{ Page = $page; Size = $pageSize }
        $items = Get-DataArray $resp
        $items = @($items | Where-Object { $_ -and ($_.deviceId -or $_.id) })
        if ($items.Count -eq 0) { break }

        $all += $items

        $total = if ($resp.totalCount)                 { [int]$resp.totalCount }
                 elseif ($resp.meta.page.totalElements) { [int]$resp.meta.page.totalElements }
                 else                                   { $all.Count }
        if ($all.Count -ge $total) { break }
        $page++
    }

    return @($all | ForEach-Object {
        [pscustomobject]@{
            DeviceId   = $(if ($_.deviceId) { $_.deviceId } else { $_.id })
            DeviceName = $(if ($_.deviceName) { $_.deviceName } elseif ($_.name) { $_.name } else { $_.deviceId })
            ApiStatus  = $(if ($_.deviceStatus) { $_.deviceStatus } elseif ($_.status) { $_.status } else { 'UNKNOWN' })
            Raw        = $_
        }
    })
}

function Get-DeviceHeartbeats {
    <#
    .SYNOPSIS
        Ermittelt je Geraet den letzten Statistik-Heartbeat - parallel.
    .DESCRIPTION
        'device get-statistics' (V1) bzw. 'device statistics' (V2) liefert ein
        Objekt, dessen Schluessel der Unix-ms-Zeitstempel der letzten vom Geraet
        gemeldeten Statistik ist:

            { "data": { "1789714548000": "{...JSON als String...}" } }

        Das Alter dieses Zeitstempels ist der einzige belastbare Live-Indikator,
        den die IEM-API hergibt. Gemessen an einem realen IEM: laufende Geraete
        4-22 Minuten, ausgeschaltete Geraete ~18 Stunden.

        Bewusst NICHT verwendet:
          - deviceStatus ACTIVE  -> heisst nur "onboardiert", nie "online"
          - modifiedDate         -> DB-Aenderungsdatum, bei Offline-Geraeten
                                    identisch zu Online-Geraeten (verifiziert)
    #>
    param([Parameter(Mandatory)][object[]]$Devices)

    $work = foreach ($d in $Devices) {
        [pscustomobject]@{
            DeviceId   = $d.DeviceId
            DeviceName = $d.DeviceName
            IectlArgs  = [string[]](Get-ApiArgs -Op 'device.statistics' -P @{ DeviceId = $d.DeviceId })
        }
    }

    # ForEach-Object -Parallel laeuft in eigenen Runspaces: hier sind KEINE
    # Skriptfunktionen sichtbar, der iectl-Aufruf steht deshalb inline.
    $results = $work | ForEach-Object -ThrottleLimit $script:MaxParallel -Parallel {
        # Runspaces erben die Preference nicht; ohne das laufen Fehler an der
        # Fehlerbehandlung vorbei auf die Konsole statt in $err.
        $ErrorActionPreference = 'Stop'

        $item    = $_
        $hbMs    = $null
        $uptime  = $null
        $running = @()
        $err     = $null

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName               = 'iectl'
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        foreach ($a in $item.IectlArgs) { $psi.ArgumentList.Add([string]$a) }

        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi
        try {
            [void]$proc.Start()
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $errTask = $proc.StandardError.ReadToEndAsync()

            if (-not $proc.WaitForExit(120000)) {
                try { $proc.Kill($true) } catch { }
                $err = 'Timeout nach 120s'
            }
            else {
                $stdout = $outTask.GetAwaiter().GetResult()
                $stderr = $errTask.GetAwaiter().GetResult()

                if ($proc.ExitCode -ne 0) {
                    $line = ($stderr -split "`r?`n" | Where-Object { $_ -match '^\s*Error:' } | Select-Object -First 1)
                    $err  = if ($line) { $line.Trim() } else { "ExitCode $($proc.ExitCode)" }
                }
                else {
                    $j    = $stdout | ConvertFrom-Json
                    $keys = @($j.data.PSObject.Properties.Name | Where-Object { $_ -match '^\d+$' })
                    if ($keys.Count -gt 0) {
                        # @(...) ist zwingend: bei genau EINEM Schluessel liefert
                        # Sort-Object einen String statt eines Arrays, und [0]
                        # waere dann dessen erstes Zeichen ("1789..." -> "1").
                        $newest  = @($keys | Sort-Object { [long]$_ } -Descending)[0]
                        $hbMs    = [long]$newest
                        $inner   = $j.data.$newest | ConvertFrom-Json
                        $uptime  = $inner.SystemInfo.GetUptime
                        $running = @($inner.AppCount.ApplicationStatusDetail | ForEach-Object {
                            [pscustomobject]@{
                                ApplicationId = $_.applicationId
                                Title         = $_.title
                                AppStatus     = $_.appStatus
                            }
                        })
                    }
                    else {
                        $err = 'Keine Statistik-Zeitstempel in der Antwort'
                    }
                }
            }
        }
        catch { $err = $_.Exception.Message }
        finally { $proc.Dispose() }

        [pscustomobject]@{
            DeviceId    = $item.DeviceId
            DeviceName  = $item.DeviceName
            HeartbeatMs = $hbMs
            Uptime      = $uptime
            RunningApps = $running
            Error       = $err
        }
    }

    foreach ($r in $results) {
        if ($r.Error) { Write-Log "Heartbeat $($r.DeviceName): FEHLER - $($r.Error)" 'WARN' }
        else          { Write-Log "Heartbeat $($r.DeviceName): $($r.HeartbeatMs) (Uptime $($r.Uptime))" 'INFO' }
    }
    return @($results)
}

function Get-OnlineState {
    param([Nullable[long]]$HeartbeatMs, [long]$NowMs)
    if (-not $HeartbeatMs) { return 'UNKNOWN' }
    $ageMin = ($NowMs - $HeartbeatMs) / 60000.0
    if ($ageMin -le $script:OnlineMaxAgeMin)  { return 'ONLINE'  }
    if ($ageMin -ge $script:OfflineMinAgeMin) { return 'OFFLINE' }
    return 'UNKNOWN'
}

function Format-Age {
    param([Nullable[long]]$HeartbeatMs, [long]$NowMs)
    if (-not $HeartbeatMs) { return 'kein Heartbeat' }
    $min = ($NowMs - $HeartbeatMs) / 60000.0
    if ($min -lt 90)   { return ('vor {0:N0} min' -f $min) }
    if ($min -lt 2880) { return ('vor {0:N1} h'   -f ($min / 60)) }
    return ('vor {0:N1} Tagen' -f ($min / 1440))
}

function Get-DeviceLiveState {
    <#
    .SYNOPSIS
        Liefert je Geraet Online-Status und eine kurze Statusbeschreibung -
        API-uebergreifend vereinheitlicht, aber pro API unterschiedlich ermittelt.
    .DESCRIPTION
        V1: liefert keinen verlaesslichen Live-Status (deviceStatus ACTIVE
            heisst nur "onboardiert"). Ersatz: Alter des letzten Statistik-
            Heartbeats via Get-DeviceHeartbeats (parallel, ein Aufruf je Geraet).

        V2: 'device list' liefert das Feld 'status' ("Online"/"Offline")
            direkt mit - kein Zusatzaufruf noetig. Auf einem realen IEM mit
            v2-Migration verifiziert: deckungsgleich mit dem V1-Heartbeat-
            Befund auf denselben Geraeten.
    #>
    param([Parameter(Mandatory)][object[]]$Devices)

    if ($script:Api.Version -ne 'V1') {
        return @($Devices | ForEach-Object {
            $raw   = [string]$_.ApiStatus
            $state = switch -Regex ($raw) {
                '^Online$'  { 'ONLINE' }
                '^Offline$' { 'OFFLINE' }
                default     { 'UNKNOWN' }
            }
            [pscustomobject]@{
                DeviceId     = $_.DeviceId
                OnlineState  = $state
                StatusDetail = "IEM meldet: $raw"
                Uptime       = $null
            }
        })
    }

    $heartbeats = Get-DeviceHeartbeats -Devices $Devices
    $nowMs      = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $hbByDev    = @{}
    foreach ($h in $heartbeats) { $hbByDev[$h.DeviceId] = $h }

    return @($Devices | ForEach-Object {
        $hb = $hbByDev[$_.DeviceId]
        [pscustomobject]@{
            DeviceId     = $_.DeviceId
            OnlineState  = Get-OnlineState -HeartbeatMs $(if ($hb) { $hb.HeartbeatMs } else { $null }) -NowMs $nowMs
            StatusDetail = Format-Age    -HeartbeatMs $(if ($hb) { $hb.HeartbeatMs } else { $null }) -NowMs $nowMs
            Uptime       = $(if ($hb) { $hb.Uptime } else { $null })
        }
    })
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: App-Bestand je Geraet
# ─────────────────────────────────────────────────────────────────────────────

function Get-DeviceInventory {
    <#
    .SYNOPSIS
        Liefert je DeviceId die installierte Version der gewaehlten App.
    .DESCRIPTION
        V1: ein einziger 'device list-apps'-Aufruf OHNE --deviceid liefert den
            Bestand ALLER Geraete auf einmal (laut CLI-Hilfe und verifiziert).
            Das ersetzt n Einzelaufrufe.

        V2: 'device list' liefert je Geraet ein "installedApplications"-Array
            (id/name/version) direkt mit - kein Zusatzaufruf noetig. Ist
            $Devices bereits frisch geladen (mit .Raw, z.B. direkt nach
            Get-AllDevices), wird das wiederverwendet; mit -ForceRefresh
            (Verifikation NACH einem Job) wird zwingend neu geladen, damit
            kein Stand von vor dem Job verwendet wird.
    #>
    param(
        [Parameter(Mandatory)][string]$AppId,
        [object[]]$Devices = @(),
        [switch]$ForceRefresh
    )

    $inventory = @{}

    if ($script:Api.InventorySource -eq 'ListApps') {
        Write-Step 'Loading installed apps for all devices (one call)...'
        $resp = Invoke-Api -Op 'device.apps.all'
        foreach ($entry in (Get-DataArray $resp)) {
            if (-not $entry.deviceId) { continue }
            if ($entry.applicationId -ne $AppId) { continue }
            $ver = if ($entry.versionNumber) { $entry.versionNumber }
                   elseif ($entry.version)   { $entry.version }
                   else                      { 'unbekannt' }
            $inventory[$entry.deviceId] = [pscustomobject]@{
                Version   = $ver
                VersionId = $(if ($entry.versionId) { $entry.versionId } else { $entry.verionId })  # API-Tippfehler 'verionId'
                AppStatus = $entry.status
                Source    = 'list-apps'
            }
        }
        Write-Success "Inventory determined for $($inventory.Count) device(s)."
        return $inventory
    }

    # ---- V2: direkt in der Geraeteliste enthalten --------------------------
    $source     = $Devices
    $needsFetch = $ForceRefresh -or $source.Count -eq 0 -or -not $source[0].PSObject.Properties['Raw']
    if ($needsFetch) {
        Write-Step 'Loading current device inventory (app version is included)...'
        $source = Get-AllDevices
    }

    foreach ($d in $source) {
        $apps = $d.Raw.installedApplications
        if (-not $apps) { continue }
        $match = $apps | Where-Object { $_.id -eq $AppId } | Select-Object -First 1
        if ($match) {
            $inventory[$d.DeviceId] = [pscustomobject]@{
                Version   = $match.version
                VersionId = $match.versionId
                AppStatus = $null
                Source    = 'device-list'
            }
        }
    }
    Write-Success "Inventory determined for $($inventory.Count) device(s)."
    return $inventory
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Geraetezeilen fuer die Auswahl
# ─────────────────────────────────────────────────────────────────────────────

function New-DeviceRows {
    param(
        [Parameter(Mandatory)][object[]]$Devices,
        [Parameter(Mandatory)][object[]]$LiveStates,
        [Parameter(Mandatory)][hashtable]$Inventory,
        [Parameter(Mandatory)][object]$TargetVersion
    )

    $liveByDev = @{}
    foreach ($l in $LiveStates) { $liveByDev[$l.DeviceId] = $l }
    $isUninstall = ($TargetVersion.Operation -eq 'uninstallApplication')

    return @($Devices | ForEach-Object {
        $dev  = $_
        $live = $liveByDev[$dev.DeviceId]
        $inv  = $Inventory[$dev.DeviceId]

        $online = $(if ($live) { $live.OnlineState }  else { 'UNKNOWN' })
        $detail = $(if ($live) { $live.StatusDetail } else { 'no status determined' })

        $installed   = $(if ($inv) { $inv.Version } else { '(not installed)' })
        $isInstalled = ($null -ne $inv)

        # Aktion und Sperrgrund bestimmen
        $isUpToDate  = $false
        $isDowngrade = $false
        $lockReason  = $null

        if ($isUninstall) {
            $actionText = if ($isInstalled) { "uninstall (v$installed)" } else { '-' }
            if (-not $isInstalled) { $lockReason = 'App not installed' }
        }
        elseif (-not $isInstalled) {
            $actionText = "install new -> v$($TargetVersion.Version)"
        }
        elseif (-not (Test-IsRealVersion $installed)) {
            # Version unbekannt (V2-Rekonstruktion ohne Treffer): nicht raten.
            $actionText = "version unknown -> v$($TargetVersion.Version)"
        }
        else {
            $cmp = Compare-SemVer $installed $TargetVersion.Version
            if ($cmp -eq 0) {
                $isUpToDate = $true
                $actionText = 'already up to date'
                $lockReason = 'already on target version'
            }
            elseif ($cmp -lt 0) {
                $actionText = "Update v$installed -> v$($TargetVersion.Version)"
            }
            else {
                $isDowngrade = $true
                $actionText  = "DOWNGRADE v$installed -> v$($TargetVersion.Version)"
            }
        }

        $statusText = "$online, $detail"

        [pscustomobject]@{
            DeviceName       = $dev.DeviceName
            DeviceId         = $dev.DeviceId
            ApiStatus        = $dev.ApiStatus
            OnlineState      = $online
            StatusDetail     = $detail
            Uptime           = $(if ($live) { $live.Uptime } else { $null })
            InstalledVersion = $installed
            InstalledSource  = $(if ($inv) { $inv.Source } else { $null })
            AppStatus        = $(if ($inv) { $inv.AppStatus } else { $null })
            IsInstalled      = $isInstalled
            IsUpToDate       = $isUpToDate
            IsDowngrade      = $isDowngrade
            TargetVersion    = $TargetVersion.Version
            StatusText       = $statusText
            ActionText       = $actionText
            LockReason       = $lockReason
            # Harte Sperre (App fehlt bei Deinstallation / bereits aktuell) -
            # bleibt IMMER gesperrt, auch mit Offline-Freischaltung.
            IsLocked         = ($null -ne $lockReason)
            # Weiche Sperre: nicht sicher online. Per Default nicht waehlbar,
            # aber ueber die 'O'-Taste in Select-DevicesCheckbox freischaltbar
            # (siehe dort) - dann normal waehlbar, nur farblich markiert.
            RequiresOfflineUnlock = ($online -ne 'ONLINE')
        }
    })
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Operation bestimmen
# ─────────────────────────────────────────────────────────────────────────────

function Resolve-Operation {
    <#
        Legt die auszufuehrende Operation fest.

        WICHTIG: Eine gewaehlte Deinstallation wird hier sofort und
        bedingungslos zurueckgegeben. In V5 lief nach dem Setzen von
        'uninstallApplication' die nachfolgende if/elseif-Kette weiter und
        ueberschrieb den Wert mit 'updateApplication' - woraufhin eine
        versionId verlangt wurde, die es bei einer Deinstallation nicht gibt.
    #>
    param(
        [Parameter(Mandatory)][object]$Version,
        [Parameter(Mandatory)][object[]]$Devices
    )

    if ($Version.Operation -eq 'uninstallApplication') {
        Write-Info 'Operation: uninstallApplication' -Color DarkYellow
        return 'uninstallApplication'
    }

    $newCount = @($Devices | Where-Object { -not $_.IsInstalled }).Count
    $updCount = @($Devices | Where-Object { $_.IsInstalled }).Count

    if ($newCount -gt 0 -and $updCount -gt 0) {
        Write-Warn "Mixed selection: $newCount device(s) without the app, $updCount device(s) with it."
        Write-Host '  [1] installApplication  (suitable for all, including updates)'
        Write-Host '  [2] updateApplication   (only for already-installed apps)'
        $choice = (Read-Host 'Operation').Trim()
        $op = if ($choice -eq '2') { 'updateApplication' } else { 'installApplication' }
        Write-Info "Operation: $op" -Color Cyan
        return $op
    }

    if ($updCount -gt 0) {
        Write-Info 'Operation: updateApplication' -Color Cyan
        return 'updateApplication'
    }

    Write-Info 'Operation: installApplication' -Color Cyan
    return 'installApplication'
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Job-Ausfuehrung
# ─────────────────────────────────────────────────────────────────────────────

function Get-InstalledJobId {
    <#
        'device-job-wait --id' erwartet laut CLI-Hilfe ausdruecklich die
        installedJobId. Diese wird deshalb bevorzugt; id/jobId sind nur
        Rueckfallebenen fuer abweichende Antwortformate.
    #>
    param([object]$Job)
    foreach ($p in 'installedJobId', 'jobId', 'id') {
        if ($Job.PSObject.Properties[$p] -and $Job.$p) { return [string]$Job.$p }
    }
    return $null
}

function Invoke-AppBatch {
    <# Erstellt einen Batch-Auftrag und gibt die Batch-ID zurueck. #>
    param(
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][object[]]$Devices,
        [string]$VersionId
    )

    if ($Operation -ne 'uninstallApplication' -and [string]::IsNullOrWhiteSpace($VersionId)) {
        throw "Operation '$Operation' requires a versionId, but none was provided."
    }

    $deviceIds  = @($Devices | ForEach-Object { $_.DeviceId })
    $infoMap    = ([pscustomobject]@{ devices = $deviceIds } | ConvertTo-Json -Compress -Depth 3)

    $p = @{
        AppId     = $AppId
        Operation = $Operation
        InfoMap   = $infoMap
        # Bei einer Deinstallation darf --versionId NICHT gesetzt werden.
        VersionId = $(if ($Operation -eq 'uninstallApplication') { $null } else { $VersionId })
    }

    Write-Info "Operation:  $Operation"
    Write-Info "App ID:     $AppId"
    if ($p.VersionId) { Write-Info "Version ID: $($p.VersionId)" }
    Write-Info "Devices: $($deviceIds.Count)"

    $result = Invoke-Api -Op 'job.batchCreate' -P $p

    $batchId = if ($result.batchId)                { $result.batchId }
               elseif ($result.id)                 { $result.id }
               elseif ($result.data -is [string])  { $result.data.Trim() }
               elseif ($result.data.batchId)       { $result.data.batchId }
               elseif ($result -is [string])       { $result.Trim() }
               else                                { $null }

    return $batchId
}

function Get-BatchDeviceJobs {
    <#
        Holt die Einzel-Device-Jobs eines Batches. batch-status meldet nur, ob
        die Jobs ERZEUGT wurden (READY -> in Erstellung, PROCESSED -> erstellt),
        NICHT ob sie fertig sind. Deshalb wird auf PROCESSED gewartet und
        anschliessend ueber die Device-Jobs weitergearbeitet.
    #>
    param([Parameter(Mandatory)][string]$BatchId, [int]$CreationTimeoutSec = 180)

    $elapsed  = 0
    $interval = 10

    while ($elapsed -lt $CreationTimeoutSec) {
        $st = Invoke-Api -Op 'job.batchStatus' -P @{ BatchId = $BatchId } -AllowFailure
        $statusVal = if (-not $st.Success) { $null }
                     elseif ($st.Data -is [string]) { $st.Data.Trim() }
                     elseif ($st.Data.data -is [string]) { $st.Data.data.Trim() }
                     elseif ($st.Data.status) { $st.Data.status }
                     else { ($st.Data | ConvertTo-Json -Compress -Depth 3) }

        Write-Host "  [${elapsed}s] Batch status: $statusVal" -ForegroundColor DarkGray
        Write-Log "Batch-Status [${elapsed}s]: $statusVal" 'INFO'

        if ($statusVal -in @('PROCESSED', 'COMPLETED')) { break }
        if ($statusVal -in @('FAILED', 'ERROR')) {
            Write-Err "Batch creation failed: $statusVal"
            return @()
        }

        Start-Sleep -Seconds $interval
        $elapsed += $interval
    }

    $jobsResp = Invoke-Api -Op 'job.batchJobs' -P @{ BatchId = $BatchId } -AllowFailure
    if (-not $jobsResp.Success) {
        Write-Warn "Could not fetch job list for batch: $($jobsResp.Error)"
        return @()
    }

    $jobs = @(Get-DataArray $jobsResp.Data | Where-Object { $_ -and (Get-InstalledJobId $_) })
    Write-Log "$($jobs.Count) Device-Job(s) fuer Batch $BatchId gefunden." 'INFO'
    return $jobs
}

function Wait-DeviceJobs {
    <#
    .SYNOPSIS
        Wartet parallel (gedrosselt) auf die Einzeljobs.
    .DESCRIPTION
        WICHTIG (live gefunden): 'device-job-wait' beendet sich beim
        Erreichen seines --timeout mit ExitCode 0 und liefert im JSON-Body
        {"resourceStatus":{"status":"timeout"}} - das ist KEIN Fehler auf
        Prozessebene. Eine fruehere Fassung dieser Funktion wertete nur den
        ExitCode aus und meldete das faelschlich als "Job abgeschlossen",
        obwohl der Job schlicht noch nicht fertig war.

        Auf dem getesteten IEM brauchen manche Jobs (v.a. Erstinstallationen
        mit Image-Pull, aber auch Updates auf ein neues Image) laenger als
        ein einzelnes 120s-Fenster. Deshalb wird bei Status 'timeout'
        automatisch bis zu $script:JobWaitMaxAttempts mal erneut gewartet.
        Nur 'completed' gilt als Erfolg; jeder andere Status oder ein
        echter iectl-Fehler beendet den Versuch sofort ohne weiteren Retry.

        Jobs auf Geraeten, die bereits VOR dem Batch nicht sicher online
        waren (-OfflineDeviceIds), werden NICHT abgewartet: IEM stellt den
        Job dafuer einfach auf PENDING, bis das Geraet wieder verbunden ist -
        ein Warten (erst recht mit Retries, also bis zu mehreren Minuten)
        wuerde nur den vorhersehbaren Timeout abwarten, ohne dass in dieser
        Zeit irgendetwas passieren kann. Solche Jobs werden sofort als
        "eingereiht" gemeldet (keine echte Erfolgs- oder Fehlermeldung).
    #>
    param(
        [Parameter(Mandatory)][object[]]$Jobs,
        [string[]]$OfflineDeviceIds = @()
    )

    $offlineSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$OfflineDeviceIds)

    $work = foreach ($j in $Jobs) {
        $jid   = Get-InstalledJobId $j
        $devId = [string]$j.objectId
        [pscustomobject]@{
            JobId          = $jid
            DeviceId       = $devId
            DeviceName     = $(if ($j.deviceName) { $j.deviceName } elseif ($devId) { $devId } else { 'unbekannt' })
            IsKnownOffline = $offlineSet.Contains($devId)
            IectlArgs      = [string[]](Get-ApiArgs -Op 'job.wait' -P @{ JobId = $jid; TimeoutSec = $script:JobWaitTimeoutSec })
        }
    }

    $skipped = @($work | Where-Object { $_.IsKnownOffline })
    foreach ($s in $skipped) {
        Write-Warn "$($s.DeviceName): device offline - job queued (PENDING), will run once reconnected. Not waiting."
        Write-Log "Job $($s.JobId) ($($s.DeviceName)) UEBERSPRUNGEN - Geraet bereits vor dem Batch offline." 'INFO'
    }
    $toWait = @($work | Where-Object { -not $_.IsKnownOffline })

    if ($toWait.Count -eq 0) {
        return @($skipped | ForEach-Object {
            [pscustomobject]@{ JobId = $_.JobId; DeviceName = $_.DeviceName; Ok = $false; Queued = $true; Error = 'Device offline - queued'; Output = $null; Attempts = 0 }
        })
    }

    $jobWaitTimeoutSec = $script:JobWaitTimeoutSec
    $maxAttempts       = $script:JobWaitMaxAttempts
    $timeoutMs         = ($jobWaitTimeoutSec + 30) * 1000

    Write-Step ("Waiting for {0} device job(s), max. {1} parallel, up to {2}x{3}s per job..." -f `
        $toWait.Count, $script:MaxParallel, $maxAttempts, $jobWaitTimeoutSec)

    # -AsJob statt einem direkt blockierenden Aufruf: so kann die aeussere
    # Schleife alle 10s ein Lebenszeichen ausgeben, waehrend im Hintergrund
    # gewartet wird - ohne das waere ueber mehrere Minuten (mehrere Retries
    # a 120s) keinerlei Rueckmeldung sichtbar.
    $job = $toWait | ForEach-Object -ThrottleLimit $script:MaxParallel -AsJob -Parallel {
        $ErrorActionPreference = 'Stop'

        $item         = $_
        $maxAttempts  = $using:maxAttempts
        $timeoutMs    = $using:timeoutMs
        $tSec         = $using:jobWaitTimeoutSec
        $ok           = $false
        $err          = $null
        $out          = $null
        $attemptsUsed = 0

        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            $attemptsUsed = $attempt

            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName               = 'iectl'
            $psi.UseShellExecute        = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow         = $true
            foreach ($a in $item.IectlArgs) { $psi.ArgumentList.Add([string]$a) }

            $proc = [System.Diagnostics.Process]::new()
            $proc.StartInfo = $psi
            $procHung = $false
            try {
                [void]$proc.Start()
                $outTask = $proc.StandardOutput.ReadToEndAsync()
                $errTask = $proc.StandardError.ReadToEndAsync()
                if (-not $proc.WaitForExit($timeoutMs)) {
                    try { $proc.Kill($true) } catch { }
                    $err      = 'device-job-wait process did not respond (hard timeout)'
                    $procHung = $true
                }
                else {
                    $out = $outTask.GetAwaiter().GetResult().Trim()
                    $se  = $errTask.GetAwaiter().GetResult()
                    if ($proc.ExitCode -eq 0) {
                        $status = $null
                        try { $status = ($out | ConvertFrom-Json).resourceStatus.status } catch { }
                        if ($status -eq 'completed') {
                            $ok = $true
                        }
                        elseif ($status -eq 'timeout') {
                            $err = "Job not yet completed after ${attempt}x${tSec}s (status still 'timeout')"
                            # Kein 'break': naechster Versuch, sofern noch welche uebrig sind.
                        }
                        else {
                            $err = "Unexpected job status: '$status'"
                            break
                        }
                    }
                    else {
                        $line = ($se -split "`r?`n" | Where-Object { $_ -match '^\s*Error:' } | Select-Object -First 1)
                        $err  = if ($line) { $line.Trim() } else { "ExitCode $($proc.ExitCode)" }
                        break
                    }
                }
            }
            catch { $err = $_.Exception.Message }
            finally { $proc.Dispose() }

            if ($ok -or $procHung) { break }
        }

        [pscustomobject]@{ JobId = $item.JobId; DeviceName = $item.DeviceName; Ok = $ok; Queued = $false; Error = $err; Output = $out; Attempts = $attemptsUsed }
    }

    $pollIntervalSec = 10
    $maxTotalSec     = $maxAttempts * $jobWaitTimeoutSec
    $waitedSec       = 0
    while ($job.State -eq 'Running') {
        if (-not (Wait-Job -Job $job -Timeout $pollIntervalSec)) {
            $waitedSec += $pollIntervalSec
            Write-Host "  ... still waiting for device job(s), waited (${waitedSec}s/max. ${maxTotalSec}s)..." -ForegroundColor DarkGray
        }
    }
    $waited  = @(Receive-Job -Job $job)
    Remove-Job -Job $job -Force
    $results = @($waited) + @($skipped | ForEach-Object {
        [pscustomobject]@{ JobId = $_.JobId; DeviceName = $_.DeviceName; Ok = $false; Queued = $true; Error = 'Device offline - queued'; Output = $null; Attempts = 0 }
    })

    # Einzelgeraetefehler werden protokolliert, brechen den Lauf aber nicht ab.
    foreach ($r in ($results | Sort-Object DeviceName)) {
        if ($r.Ok) {
            Write-Success "$($r.DeviceName): job completed (after $($r.Attempts) attempt(s))."
            Write-Log "Job $($r.JobId) ($($r.DeviceName)) OK nach $($r.Attempts) Versuch(en): $($r.Output)" 'OK'
        }
        elseif ($r.Queued) {
            # Bereits oben als Warnung ausgegeben - hier nur noch geloggt.
            Write-Log "Job $($r.JobId) ($($r.DeviceName)) EINGEREIHT (Geraet offline)." 'INFO'
        }
        else {
            Write-Err "$($r.DeviceName): $($r.Error)"
            Write-Log "Job $($r.JobId) ($($r.DeviceName)) FEHLER nach $($r.Attempts) Versuch(en): $($r.Error)" 'ERROR'
        }
    }
    return @($results)
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: State - Konfiguration
# ─────────────────────────────────────────────────────────────────────────────

function Get-IemConfigs {
    <#
    .SYNOPSIS
        Liest alle 'iem'-Konfigurationen aus 'iectl config list'.
    .DESCRIPTION
        WICHTIG (live gefunden): 'inactive.iem' ist bei iectl tatsaechlich
        ein Register ALLER bekannten iem-Configs, nicht nur der inaktiven -
        die gerade aktive Config taucht dort WEITERHIN mit auf. 'active.iem'
        ist lediglich der Zeiger darauf, welche davon momentan gewaehlt ist.
        Ohne Deduplizierung nach Name erschien die aktive Config doppelt
        (einmal als [aktiv], einmal als [inaktiv]) im Konfigurationsmenue.
    #>
    Write-Log 'Ausfuehren: iectl config list' 'CMD'
    $raw = (& iectl config list 2>&1 | Out-String)
    Write-Log "config list: $raw" 'DATA'

    $configs = @()
    try {
        $parsed = $raw | ConvertFrom-Json
        foreach ($section in @('active', 'inactive')) {
            if (-not $parsed.$section) { continue }
            $iemNode = $parsed.$section.iem
            if (-not $iemNode) { continue }

            if ($iemNode.name) {
                # Aktive Config: direkt das Config-Objekt
                $configs += [pscustomobject]@{
                    Name     = $iemNode.name
                    Url      = $iemNode.values.url
                    User     = $iemNode.values.user
                    IsActive = ($section -eq 'active')
                }
            }
            else {
                # Register aller Configs: Map name -> Config-Objekt
                foreach ($prop in $iemNode.PSObject.Properties) {
                    $cfg = $prop.Value
                    if (-not $cfg -or -not $cfg.name) { continue }
                    $configs += [pscustomobject]@{
                        Name     = $cfg.name
                        Url      = $cfg.values.url
                        User     = $cfg.values.user
                        IsActive = ($section -eq 'active')
                    }
                }
            }
        }
    }
    catch { Write-Log "config list nicht parsebar: $_" 'WARN' }

    # Nach Name deduplizieren - eine als aktiv gefundene Zeile gewinnt immer
    # gegen eine gleichnamige aus dem 'inactive'-Register.
    return @($configs | Group-Object Name | ForEach-Object {
        $active = $_.Group | Where-Object IsActive | Select-Object -First 1
        if ($active) { $active } else { $_.Group[0] }
    })
}

function Set-ActiveIemConfig {
    <#
    .SYNOPSIS
        Macht die genannte Konfiguration in iectl aktiv.
    .DESCRIPTION
        Zwingend nach jeder Auswahl im Menue: iectl haelt seine aktive
        Konfiguration als eigenen, dateibasierten Zustand - unabhaengig davon,
        was der Nutzer in diesem Skript ausgewaehlt hat. Ohne diesen Aufruf
        kann das Skript "Verwende Konfiguration X" melden, waehrend iectl im
        Hintergrund weiter gegen die zuletzt aktive Konfiguration Y arbeitet.
        Das war in fruaheren Versionen die Ursache fuer Verwechslungen beim
        Wechsel zwischen zwei IEM-Instanzen.
    #>
    param([Parameter(Mandatory)][string]$Name)
    Write-Log "Ausfuehren: iectl config switch --name $Name --type iem" 'CMD'
    $out = & iectl config switch --name $Name --type iem 2>&1
    Write-Log "config switch ExitCode: $LASTEXITCODE | $($out | Out-String)" 'DATA'
    return ($LASTEXITCODE -eq 0)
}

function Invoke-StateConfig {
    Write-Header 'Step 0 - IEM configuration'
    Write-LogSeparator 'IEM-Konfiguration'

    $chosen = $null
    while ($true) {
        Write-Step 'Reading existing IEM configurations...'
        $configs = Get-IemConfigs

        if ($configs.Count -eq 0) {
            Write-Info 'No existing configuration found - a new one will be created.' -Color DarkGray
            break
        }

        Write-Success "$($configs.Count) IEM configuration(s) found."
        Write-Host ''
        for ($i = 0; $i -lt $configs.Count; $i++) {
            $c      = $configs[$i]
            $tag    = if ($c.IsActive) { '[active]  ' } else { '[inactive]' }
            $color  = if ($c.IsActive) { 'Cyan' } else { 'DarkGray' }
            Write-Host ("    [{0,2}]  {1} {2,-22} | {3} | {4}" -f ($i + 1), $tag, $c.Name, $c.Url, $c.User) -ForegroundColor $color
        }
        Write-Host ''
        Write-Host '    [ N]      Create new configuration' -ForegroundColor DarkGray
        Write-Host '    [X<No>]   Delete configuration, e.g. X2' -ForegroundColor DarkGray
        Write-Host '    [ q]      Exit script' -ForegroundColor DarkGray
        Write-Host ''

        $sel = (Read-Host 'Choose configuration').Trim()
        Write-Log "Config-Auswahl: '$sel'" 'INFO'

        if ($sel -match '^[qQ]$') { return 'EXIT' }
        if ($sel -match '^[nN]$') { break }

        if ($sel -match '^[xX](\d+)$') {
            $n = [int]$Matches[1]
            if ($n -lt 1 -or $n -gt $configs.Count) {
                Write-Warn "Invalid number to delete: $n"
                continue
            }
            $target = $configs[$n - 1]
            $confirm = (Read-Host "Really delete configuration '$($target.Name)' ($($target.Url))? [y/N]").Trim()
            Write-Log "Loeschbestaetigung fuer '$($target.Name)': '$confirm'" 'INFO'
            if ($confirm -match '^[jJyY]') {
                Write-Log "Ausfuehren: iectl config delete --name $($target.Name) --type iem" 'CMD'
                $delOut = & iectl config delete --name $target.Name --type iem 2>&1
                Write-Log "config delete ExitCode: $LASTEXITCODE | $($delOut | Out-String)" 'DATA'
                if ($LASTEXITCODE -eq 0) { Write-Success "Configuration '$($target.Name)' deleted." }
                else { Write-Err "Configuration could not be deleted: $delOut" }
            }
            continue
        }

        if ($sel -match '^\d+$') {
            $n = [int]$sel
            if ($n -ge 1 -and $n -le $configs.Count) {
                $chosen = $configs[$n - 1]
                break
            }
        }
        Write-Warn "Invalid input. 1 to $($configs.Count), N, X<No> or q."
    }

    if ($chosen) {
        if ($chosen.IsActive) {
            # Already active - 'iectl config switch' has been observed to
            # ALWAYS fail here ("inactive item ... not found"), because an
            # item that is already active is by definition not found in the
            # inactive registry. Without this check, the script aborted
            # completely whenever the already-active configuration was chosen.
            $script:ConfigName = $chosen.Name
            Write-Success "Using configuration: '$($chosen.Name)' ($($chosen.Url)) (already active)"
        }
        else {
            Write-Step "Activating configuration '$($chosen.Name)'..."
            if (-not (Set-ActiveIemConfig -Name $chosen.Name)) {
                Write-Err "Configuration '$($chosen.Name)' could not be activated (iectl config switch failed)."
                return 'EXIT'
            }
            $script:ConfigName = $chosen.Name
            Write-Success "Using configuration: '$($chosen.Name)' ($($chosen.Url))"
        }
    }
    else {
        Write-Step 'Creating new IEM configuration...'
        $name = (Read-Host 'Configuration name (default: local-iem)').Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { $name = 'local-iem' }
        $url  = (Read-Host 'IEM URL (e.g. https://my-iem.example.com)').Trim()
        # iectl verlangt ein Schema; ohne das quittiert es mit "invalid url" -
        # bei einer internen IEM-Instanz ist https:// praktisch immer gemeint.
        if ($url -and $url -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
            $url = "https://$url"
            Write-Info "No scheme given - using: $url" -Color DarkGray
        }
        $user = (Read-Host 'Username').Trim()
        $securePw = Read-Host -AsSecureString 'Password'
        $plainPw  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePw))

        Write-Log "Ausfuehren: iectl config add iem --name $name --url $url --user $user --password-stdin" 'CMD'
        # WICHTIG: Ausgabe zwingend abfangen. Ohne Zuweisung landet die
        # mehrzeilige iectl-Ausgabe (z.B. der Usage-Text bei einem Fehler,
        # eine Zeile pro Pipeline-Objekt) direkt im Rueckgabewert dieser
        # Funktion. Der aufrufende State-Machine-Dispatcher haette das dann
        # als vielelementiges Array statt eines einzelnen Statusnamens
        # bekommen - jedes Element loest im switch einzeln den "Unbekannter
        # Zustand"-Zweig aus (live beobachtet: ca. 20 Wiederholungen, eine
        # pro Zeile des geleakten Usage-Texts).
        $addOut = $plainPw | & iectl config add iem --name $name --url $url --user $user --password-stdin 2>&1
        Write-Log "config add ExitCode: $LASTEXITCODE | $($addOut | Out-String)" 'DATA'
        if ($LASTEXITCODE -ne 0) {
            $reason = ($addOut | Where-Object { $_ -match '^\s*Error:' } | Select-Object -First 1)
            Write-Err "Configuration could not be created: $(if ($reason) { $reason.ToString().Trim() } else { $addOut | Out-String })"
            return 'CONFIG'
        }
        # 'config add' already activates the new configuration automatically.
        # An additional 'config switch' to the name that was just created
        # (and is therefore already active) has been observed to ALWAYS fail
        # with "inactive item ... not found" - so deliberately no further
        # switch call here (see also Invoke-StateConfig above).
        $script:ConfigName = $name
        Write-Success "Configuration '$name' created."
    }

    # TLS
    Write-Host ''
    $tls = ''
    while ($tls -notin @('1', '2')) {
        $tls = (Read-Host 'Use self-signed certificate? [1] Yes / [2] No').Trim()
        if ($tls -notin @('1', '2')) { Write-Warn 'Please enter only 1 or 2.' }
    }
    if ($tls -eq '1') {
        $env:EDGE_SKIP_TLS = '1'
        Write-Warn 'EDGE_SKIP_TLS=1 set - TLS verification disabled.'
    }
    else {
        $env:EDGE_SKIP_TLS = $null
        Write-Info 'TLS verification active.'
    }
    Write-Log "TLS-Skip: $tls" 'INFO'

    if (-not $SkipPreflight) {
        if (-not (Invoke-Preflight)) {
            Write-Warn 'Aborted - back to configuration selection.'
            return 'CONFIG'
        }
    }

    return 'MODE'
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: State - Moduswahl
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-StateMode {
    Write-Header 'Choose mode'
    Write-Host '  What would you like to do?' -ForegroundColor White
    Write-Host '  [1] Install / update / uninstall app'
    Write-Host '  [2] Update firmware'
    Write-Host '  [q] Back to IEM configuration'
    Write-Host ''

    while ($true) {
        $sel = (Read-Host 'Mode').Trim()
        Write-Log "Moduswahl: '$sel'" 'INFO'
        if ($sel -match '^[qQ]$') { return 'CONFIG' }
        if ($sel -eq '1') { return 'APP' }
        if ($sel -eq '2') { return 'FIRMWARE' }
        Write-Warn 'Please enter 1, 2 or q.'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: State - App-Auswahl
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-StateApp {
    Write-Header 'Step 1 - Choose app from IEM catalog'
    Write-LogSeparator 'App-Katalog'

    if ($script:AppCatalog.Count -eq 0) {
        Write-Step 'Loading app catalog...'
        try {
            $resp = Invoke-Api -Op 'catalog.list'
        }
        catch {
            Write-Err "App catalog not reachable: $_"
            return 'MODE'
        }

        $script:AppCatalog = @(Get-DataArray $resp | ForEach-Object {
            $name  = if ($_.title) { $_.title } elseif ($_.name) { $_.name } else { $_.applicationId }
            $appId = if ($_.applicationId) { $_.applicationId } elseif ($_.id) { $_.id } else { '' }
            [pscustomobject]@{
                Display = "$name  (ID: $appId)"
                Name    = $name
                Id      = $appId
            }
        } | Where-Object { $_.Id })
    }

    if ($script:AppCatalog.Count -eq 0) {
        Write-Warn 'No apps found in the catalog.'
        return 'MODE'
    }
    Write-Success "$($script:AppCatalog.Count) app(s) in the catalog."
    Write-Host ''

    $sel = Select-FromList -Items $script:AppCatalog -DisplayProperty 'Display' `
                           -Prompt 'Choose app (number, q = back to mode selection)'
    if ($null -eq $sel) { return 'MODE' }

    $script:SelectedApp = $sel
    Write-Success "Selected app: $($sel.Name)  (ID: $($sel.Id))"
    Write-Log "App gewaehlt: '$($sel.Name)' | ID: $($sel.Id)" 'OK'
    return 'VERSION'
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: State - Versions-/Aktionsauswahl
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-StateVersion {
    Write-Header "Step 2 - Version / action for '$($script:SelectedApp.Name)'"
    Write-LogSeparator 'Versionsauswahl'

    Write-Step 'Loading app details...'
    try {
        $details = Invoke-Api -Op 'catalog.details' -P @{ AppId = $script:SelectedApp.Id }
    }
    catch {
        Write-Err "App details not reachable: $_"
        return 'APP'
    }

    $rawVersions = if ($details.data -and $details.data.versions) { $details.data.versions }
                   elseif ($details.versions)                     { $details.versions }
                   elseif ($details.appVersions)                  { $details.appVersions }
                   else                                            { @() }

    $script:AppVersions = @($rawVersions | ForEach-Object {
        $ver = if ($_.version) { $_.version } elseif ($_.number) { $_.number } elseif ($_.versionNumber) { $_.versionNumber } else { $_.id }
        $vid = if ($_.versionId) { $_.versionId } elseif ($_.id) { $_.id } else { '' }
        [pscustomobject]@{
            Display   = "v$ver"
            Version   = [string]$ver
            VersionId = [string]$vid
            Operation = 'installApplication'
        }
    } | Where-Object { $_.VersionId })

    if ($script:AppVersions.Count -eq 0) {
        Write-Warn 'No versions found for this app.'
        return 'APP'
    }

    # Neueste Katalogversion hervorheben
    $newest = $null
    foreach ($v in $script:AppVersions) {
        if (-not $newest -or (Compare-SemVer $v.Version $newest) -gt 0) { $newest = $v.Version }
    }

    $choices = @($script:AppVersions | ForEach-Object {
        $tag = if ($_.Version -eq $newest) { '  <- newest in catalog' } else { '' }
        [pscustomobject]@{
            Display   = "v$($_.Version)$tag"
            Version   = $_.Version
            VersionId = $_.VersionId
            Operation = 'installApplication'
        }
    })
    $choices += [pscustomobject]@{
        Display   = '[D] Uninstall app'
        Version   = '(Uninstall)'
        VersionId = ''
        Operation = 'uninstallApplication'
    }

    Write-Success "$($script:AppVersions.Count) version(s) in the catalog."
    Write-Host ''

    $sel = Select-FromList -Items $choices -DisplayProperty 'Display' `
                           -Prompt 'Choose version/action (number, q = back to app selection)'
    if ($null -eq $sel) { return 'APP' }

    $script:SelectedVersion = $sel
    Write-Success "Target: $($sel.Version)  [Operation: $($sel.Operation)]"
    Write-Log "Ziel/Aktion: '$($sel.Version)' | Operation: $($sel.Operation) | VersionId: $($sel.VersionId)" 'OK'
    return 'DEVICES'
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: State - Geraeteauswahl
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-StateDevices {
    Write-Header 'Step 3 - Check and select devices'
    Write-LogSeparator 'Geraetescan'

    Write-Step 'Loading edge devices...'
    try {
        $devices = Get-AllDevices
    }
    catch {
        Write-Err "Device list not reachable: $_"
        return 'VERSION'
    }
    if ($devices.Count -eq 0) {
        Write-Warn 'No edge devices found.'
        return 'VERSION'
    }
    Write-Success "$($devices.Count) device(s) found."

    if ($script:Api.Version -eq 'V1') {
        Write-Step "Determining live status via statistics heartbeats (max. $($script:MaxParallel) parallel)..."
    }
    else {
        Write-Step 'Determining live status (already included in the "device list" call)...'
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $liveStates = Get-DeviceLiveState -Devices $devices
    $sw.Stop()
    Write-Success ("Status determined for $($liveStates.Count) device(s) in {0:N1}s." -f $sw.Elapsed.TotalSeconds)

    try {
        $inventory = Get-DeviceInventory -AppId $script:SelectedApp.Id -Devices $devices
    }
    catch {
        Write-Err "App inventory not determinable: $_"
        return 'VERSION'
    }

    $script:DeviceRows = New-DeviceRows -Devices $devices -LiveStates $liveStates `
                                          -Inventory $inventory -TargetVersion $script:SelectedVersion

    # Uebersicht
    Write-Host ''
    Write-Host ("  {0,-22} | {1,-10} | {2,-20} | {3,-14} | {4}" -f 'Device', 'Status', 'Detail', 'Installed', 'Action') -ForegroundColor White
    Write-Host ('  ' + ('-' * 112)) -ForegroundColor DarkGray
    foreach ($r in $script:DeviceRows) {
        $color = switch ($r.OnlineState) {
            'ONLINE'  { if ($r.IsUpToDate) { 'DarkGray' } elseif ($r.IsDowngrade) { 'DarkYellow' } else { 'White' } }
            'OFFLINE' { 'Red' }
            default   { 'DarkYellow' }
        }
        Write-Host ("  {0,-22} | {1,-10} | {2,-20} | {3,-14} | {4}" -f `
            $r.DeviceName, $r.OnlineState, $r.StatusDetail, $r.InstalledVersion, $r.ActionText) -ForegroundColor $color
        Write-Log ("{0} | {1} | {2} | installiert={3} | {4}" -f `
            $r.DeviceName, $r.OnlineState, $r.StatusDetail, $r.InstalledVersion, $r.ActionText) 'INFO'
    }
    Write-Host ''
    if ($script:Api.Version -eq 'V1') {
        Write-Info "Status thresholds (heartbeat age): ONLINE < $($script:OnlineMaxAgeMin) min, OFFLINE > $($script:OfflineMinAgeMin) min, UNKNOWN in between." -Color DarkGray
    }
    else {
        Write-Info 'Status comes directly from the IEM v2 API (device list -> status).' -Color DarkGray
    }

    $actionable = @($script:DeviceRows | Where-Object { -not $_.IsLocked })
    if ($actionable.Count -eq 0) {
        Write-Success 'No device needs any action.'
        Write-Host ''
        Read-Host 'Press Enter to return to version selection' | Out-Null
        return 'VERSION'
    }

    Write-Host ''
    Read-Host 'Press Enter to go to device selection' | Out-Null

    $title = "Target devices for '$($script:SelectedApp.Name)' -> $($script:SelectedVersion.Version)  (Q = back to version selection)"
    while ($true) {
        $sel = Select-DevicesCheckbox -Items $script:DeviceRows -Title $title
        if ($null -eq $sel) {
            Write-Log 'Geraeteauswahl mit Q verlassen -> zurueck zur Versionsauswahl.' 'INFO'
            return 'VERSION'
        }
        if ($sel.Count -gt 0) {
            $script:TargetDevices = $sel
            return 'CONFIRM'
        }
        Write-Warn 'No device selected. Please select at least one, or go back with Q.'
        Start-Sleep -Seconds 1
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: State - Bestaetigung
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-StateConfirm {
    Write-Header 'Step 4 - Confirmation'
    Write-LogSeparator 'Bestaetigung'

    $script:Operation = Resolve-Operation -Version $script:SelectedVersion -Devices $script:TargetDevices

    Write-Host ''
    Write-Host "  API:       $($script:Api.Root)" -ForegroundColor White
    Write-Host "  App:       $($script:SelectedApp.Name)  (ID: $($script:SelectedApp.Id))" -ForegroundColor White
    if ($script:Operation -eq 'uninstallApplication') {
        Write-Host '  Action:    UNINSTALL' -ForegroundColor DarkYellow
    }
    else {
        Write-Host "  Version:   v$($script:SelectedVersion.Version)  (VersionId: $($script:SelectedVersion.VersionId))" -ForegroundColor White
    }
    Write-Host "  Operation: $($script:Operation)" -ForegroundColor White
    Write-Host "  Devices:   $($script:TargetDevices.Count)" -ForegroundColor White
    Write-Host ("  Batches:   {0} of max. {1} devices" -f [math]::Ceiling($script:TargetDevices.Count / $script:BatchSize), $script:BatchSize) -ForegroundColor White
    Write-Host ''
    foreach ($d in $script:TargetDevices) {
        $color = switch ($d.OnlineState) { 'ONLINE' { 'Gray' } 'OFFLINE' { 'Red' } default { 'DarkYellow' } }
        Write-Host ("    - {0,-22} [{1,-9}] {2}" -f $d.DeviceName, $d.OnlineState, $d.ActionText) -ForegroundColor $color
    }
    Write-Host ''

    # Downgrade-Warnung
    $downgrades = @($script:TargetDevices | Where-Object { $_.IsDowngrade })
    if ($script:Operation -ne 'uninstallApplication' -and $downgrades.Count -gt 0) {
        Write-Host "  WARNING: $($downgrades.Count) downgrade(s) in the selection:" -ForegroundColor DarkYellow
        foreach ($d in $downgrades) {
            Write-Host ("    {0}: v{1} -> v{2}" -f $d.DeviceName, $d.InstalledVersion, $script:SelectedVersion.Version) -ForegroundColor DarkYellow
        }
        $ok = (Read-Host 'Really perform the downgrade? [y/N]').Trim()
        Write-Log "Downgrade-Bestaetigung: '$ok'" 'INFO'
        if ($ok -notmatch '^[jJyY]') { return 'DEVICES' }
        Write-Host ''
    }

    # Offline-Hinweis (nur noch Information, keine Rueckfrage): die
    # Entscheidung, ein nicht sicher online befindliches Geraet einzuplanen,
    # ist bereits bewusst in der Geraeteauswahl gefallen (dort per 'O'
    # explizit freigeschaltet) - eine zweite Rueckfrage hier waere eine
    # schlecht platzierte Wiederholung derselben Entscheidung.
    $offline = @($script:TargetDevices | Where-Object { $_.OnlineState -ne 'ONLINE' })
    if ($offline.Count -gt 0) {
        Write-Host "  NOTE: $($offline.Count) device(s) are not reliably online:" -ForegroundColor Yellow
        foreach ($d in $offline) {
            Write-Host ("    {0} [{1}] {2}" -f $d.DeviceName, $d.OnlineState, $d.StatusDetail) -ForegroundColor Yellow
        }
        Write-Info 'IEM accepts the job; it runs as soon as the device reconnects.' -Color DarkGray
        Write-Host ''
    }

    $confirm = (Read-Host 'Run the job now? [y/N]').Trim()
    Write-Log "Ausfuehrungsbestaetigung: '$confirm'" 'INFO'
    if ($confirm -notmatch '^[jJyY]') {
        Write-Warn 'Aborted - back to device selection.'
        return 'DEVICES'
    }
    return 'EXECUTE'
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: State - Ausfuehrung
# ─────────────────────────────────────────────────────────────────────────────

function Split-IntoBatches {
    <# Splits a list into groups of max. $script:BatchSize items
       (applies to app and firmware jobs alike). #>
    param([object[]]$Items)
    $batches = @()
    for ($i = 0; $i -lt $Items.Count; $i += $script:BatchSize) {
        $batches += , @($Items | Select-Object -Skip $i -First $script:BatchSize)
    }
    return , $batches
}

function Invoke-StateExecute {
    Write-Header 'Step 5 - Execution'
    Write-LogSeparator 'Ausfuehrung'

    $batches = Split-IntoBatches -Items $script:TargetDevices

    Write-Info ("{0} device(s) in {1} batch(es) of max. {2}." -f `
        $script:TargetDevices.Count, $batches.Count, $script:BatchSize) -Color Cyan

    $batchNo = 0
    foreach ($batch in $batches) {
        $batchNo++
        Write-Header "Batch $batchNo/$($batches.Count)  ($($batch.Count) devices)"

        $batchId = $null
        try {
            $batchId = Invoke-AppBatch -AppId $script:SelectedApp.Id `
                                       -Operation $script:Operation `
                                       -Devices $batch `
                                       -VersionId $script:SelectedVersion.VersionId
        }
        catch {
            # Ein fehlgeschlagener Batch beendet den Lauf nicht.
            Write-Err "Batch $batchNo could not be created: $_"
            continue
        }

        if (-not $batchId) {
            Write-Warn "Batch $batchNo : no batch ID in the response - status cannot be tracked."
            continue
        }
        Write-Success "Batch ID: $batchId"

        $jobs = Get-BatchDeviceJobs -BatchId $batchId
        if ($jobs.Count -eq 0) {
            Write-Warn 'No device jobs available for this batch - result will be assessed via verification.'
            Write-Info "Can be checked manually with: iectl $((Get-ApiArgs -Op 'job.batchStatus' -P @{ BatchId = $batchId }) -join ' ')" -Color DarkGray
            continue
        }

        # Geraete, die schon VOR dem Batch nicht sicher online waren, werden
        # nicht abgewartet (siehe Wait-DeviceJobs) - deren Job bleibt bei IEM
        # einfach PENDING, bis das Geraet wieder verbunden ist.
        $offlineIds = @($batch | Where-Object { $_.OnlineState -ne 'ONLINE' } | ForEach-Object { $_.DeviceId })
        [void](Wait-DeviceJobs -Jobs $jobs -OfflineDeviceIds $offlineIds)
    }

    return 'VERIFY'
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: State - Verifikation
# ─────────────────────────────────────────────────────────────────────────────

function Wait-ForInventorySettled {
    <#
    .SYNOPSIS
        Wartet bis zu $TimeoutSec darauf, dass der IEM-App-Bestand den je
        Geraet erwarteten Zustand zeigt.
    .DESCRIPTION
        'device-job-wait' meldet einen Job als abgeschlossen, sobald die
        Aktion auf dem Geraet ausgefuehrt wurde. Das Lesemodell (device-apps
        list-apps bzw. die in "device list" eingebetteten App-Daten) zieht
        auf dem getesteten IEM nachweislich mit spuerbarer Verzoegerung nach
        (in Live-Tests bis zu ca. 20-25 Sekunden). Ohne dieses Warten meldet
        eine sofortige Verifikation faelschlich einen Fehler, weil noch die
        vorherige Version gelesen wird.
    #>
    param(
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][hashtable]$Expected,   # DeviceId -> erwartete Version; $null/'' = erwartet: deinstalliert
        [int]$TimeoutSec = 60,
        [int]$IntervalSec = 10
    )
    $elapsed   = 0
    $inventory = @{}
    while ($true) {
        $inventory = Get-DeviceInventory -AppId $AppId -ForceRefresh
        $pending = @($Expected.Keys | Where-Object {
            $entry  = $inventory[$_]
            $actual = $(if ($entry) { $entry.Version } else { $null })
            $exp    = $Expected[$_]
            $ok     = $(if ([string]::IsNullOrEmpty($exp)) { $null -eq $entry } else { $actual -eq $exp })
            -not $ok
        })
        if ($pending.Count -eq 0 -or $elapsed -ge $TimeoutSec) {
            return [pscustomobject]@{ Inventory = $inventory; StillPending = $pending; WaitedSec = $elapsed }
        }
        Write-Host "  ... inventory not yet current for $($pending.Count) device(s), waiting (${elapsed}s/${TimeoutSec}s)..." -ForegroundColor DarkGray
        Write-Log "Verifikation wartet auf Aktualisierung: $($pending.Count) Geraet(e) noch nicht auf Zielstand (${elapsed}s)" 'INFO'
        Start-Sleep -Seconds $IntervalSec
        $elapsed += $IntervalSec
    }
}

function Invoke-StateVerify {
    Write-Header 'Step 6 - Verification'
    Write-LogSeparator 'Verifikation'

    $answer = (Read-Host 'Check the result on the target devices now? [Y/n]').Trim()
    Write-Log "Verifikation: '$answer'" 'INFO'
    if ($answer -match '^[nN]') { return 'MODE' }

    $expected = @{}
    foreach ($d in $script:TargetDevices) {
        $expected[$d.DeviceId] = $(if ($script:Operation -eq 'uninstallApplication') { $null } else { $script:SelectedVersion.Version })
    }

    Write-Step 'Loading current app inventory (waits if needed for the IEM read model to update)...'
    try {
        $settled = Wait-ForInventorySettled -AppId $script:SelectedApp.Id -Expected $expected -TimeoutSec 60 -IntervalSec 10
    }
    catch {
        Write-Err "Verification not possible: $_"
        return 'MODE'
    }
    $inventory = $settled.Inventory
    if ($settled.StillPending.Count -gt 0) {
        Write-Warn "For $($settled.StillPending.Count) device(s) the IEM inventory still does not show the expected state after $($settled.WaitedSec)s - could still be display lag."
    }

    $okCount = 0
    $failed  = @()
    Write-Host ''
    foreach ($d in $script:TargetDevices) {
        $inv          = $inventory[$d.DeviceId]
        $stillPending = $settled.StillPending -contains $d.DeviceId

        if ($script:Operation -eq 'uninstallApplication') {
            if ($null -eq $inv) {
                Write-Success "$($d.DeviceName): app uninstalled."
                $okCount++
            }
            elseif ($stillPending) {
                Write-Warn "$($d.DeviceName): inventory still shows the app present (v$($inv.Version)) - possibly display lag, check again shortly."
            }
            else {
                Write-Err "$($d.DeviceName): app still present (v$($inv.Version))."
                $failed += $d.DeviceName
            }
            continue
        }

        if ($null -eq $inv) {
            if ($stillPending) {
                Write-Warn "$($d.DeviceName): app not yet found in inventory - possibly display lag."
            }
            else {
                Write-Err "$($d.DeviceName): app not found."
                $failed += $d.DeviceName
            }
        }
        elseif ($inv.Version -eq $script:SelectedVersion.Version) {
            Write-Success "$($d.DeviceName): v$($inv.Version) installed."
            $okCount++
        }
        elseif (-not (Test-IsRealVersion $inv.Version)) {
            Write-Warn "$($d.DeviceName): app present, version not determinable (source: $($inv.Source))."
        }
        elseif ($stillPending) {
            Write-Warn "$($d.DeviceName): inventory still shows v$($inv.Version) instead of expected v$($script:SelectedVersion.Version) - possibly display lag."
        }
        else {
            Write-Err "$($d.DeviceName): v$($inv.Version) instead of expected v$($script:SelectedVersion.Version)."
            $failed += $d.DeviceName
        }
    }

    Write-Host ''
    Write-Host ("  Result: {0} of {1} device(s) as expected." -f $okCount, $script:TargetDevices.Count) -ForegroundColor White
    if ($failed.Count -gt 0) {
        Write-Err "Deviations on: $($failed -join ', ')"
        Write-Log "Verifikation FEHLER auf: $($failed -join ', ')" 'ERROR'
    }
    else {
        Write-Success 'All target devices as expected.'
    }

    Write-Host ''
    Read-Host 'Press Enter to return to mode selection' | Out-Null
    return 'MODE'
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Firmware - Release-Ermittlung (Workaround fuer defekten iectl-Befehl)
# ─────────────────────────────────────────────────────────────────────────────

function Get-IemBaseUrl {
    <# Liest die URL der aktuell aktiven iectl-Konfiguration. #>
    $raw = (& iectl config active 2>&1 | Out-String)
    try {
        $parsed = $raw | ConvertFrom-Json
        $url = $parsed.iem.values.url
        if (-not $url) { throw 'no URL found in the active configuration' }
        return $url.TrimEnd('/')
    }
    catch {
        throw "Active IEM URL could not be determined: $_"
    }
}

function Get-IemBearerToken {
    <#
    .SYNOPSIS
        Holt ein frisches Access-Token ueber iectl.
    .DESCRIPTION
        Nutzt die ohnehin konfigurierten Zugangsdaten der aktiven iectl-
        Konfiguration - keine zusaetzliche Eingabe vom Nutzer noetig. Wird
        ausschliesslich fuer den Firmware-Release-Workaround unten gebraucht;
        der App-Workflow kommt komplett ohne eigene HTTP-Aufrufe aus.
    #>
    $resp  = Invoke-Api -Op 'token.fetch'
    $token = if ($resp.data.access_token) { $resp.data.access_token } elseif ($resp.access_token) { $resp.access_token } else { $null }
    if (-not $token) { throw 'No access token received from iectl.' }
    return $token
}

function Get-FirmwareReleases {
    <#
    .SYNOPSIS
        Liefert alle Firmware-Releases fuer einen Geraetetyp, chronologisch
        aufsteigend sortiert (aelteste zuerst).
    .DESCRIPTION
        'iectl device firmware list' ist auf dem getesteten iectl-Build
        (Win-v2.18.4) clientseitig defekt: die Serverantwort verschachtelt
        "pageable.sort" inzwischen als Objekt statt als Array, was iectl's
        eigene Go-Struktur nicht mehr entgegennehmen kann - live bestaetigt
        auf V1 UND V2, auf zwei unabhaengigen IEM-Instanzen. Kein Skript-
        oder API-Berechtigungsproblem, ein iectl-Bug.

        Workaround: derselbe Endpunkt, den iectl intern anspricht, wird
        direkt per HTTP abgefragt. Das Access-Token kommt ueber
        Get-IemBearerToken (iectl selbst, also keine Zusatzeingabe vom
        Nutzer - nur Zugangsdaten + IEM-Domain sind noetig, wie beim Rest
        des Skripts auch). Das ist ein interner, nicht offiziell
        dokumentierter Endpunkt - aendert sich die Serverantwort, faellt
        ausschliesslich diese Funktion mit einer klaren Fehlermeldung aus;
        der App-Workflow ist davon vollstaendig unabhaengig.

        Ergebnis wird pro Geraetetyp im Skript-Cache gehalten, damit bei
        mehreren Geraeten desselben Typs nicht mehrfach geladen wird.
    #>
    param([Parameter(Mandatory)][string]$DeviceTypeId)
    $ErrorActionPreference = 'Stop'

    if ($script:FirmwareReleaseCache.ContainsKey($DeviceTypeId)) {
        return $script:FirmwareReleaseCache[$DeviceTypeId]
    }

    $baseUrl  = Get-IemBaseUrl
    $token    = Get-IemBearerToken
    $headers  = @{ Authorization = "Bearer $token" }
    $skipCert = [bool]$env:EDGE_SKIP_TLS

    try {
        $fwResp = Invoke-RestMethod -Uri "$baseUrl/firmwaremanagement/api/v1/firmware?deviceTypeId=$DeviceTypeId&size=1" `
                                    -Headers $headers -SkipCertificateCheck:$skipCert -TimeoutSec 30
    }
    catch {
        throw "Firmware product for device type '$DeviceTypeId' not reachable (internal endpoint, may have changed): $_"
    }

    $firmwareId = $fwResp.content[0].id
    if (-not $firmwareId) {
        $script:FirmwareReleaseCache[$DeviceTypeId] = @()
        return @()
    }

    try {
        $relResp = Invoke-RestMethod -Uri "$baseUrl/firmwaremanagement/api/v1/releases?firmwareId=$firmwareId&size=200" `
                                     -Headers $headers -SkipCertificateCheck:$skipCert -TimeoutSec 30
    }
    catch {
        throw "Firmware releases for '$firmwareId' not reachable (internal endpoint, may have changed): $_"
    }

    $releases = @($relResp.content | ForEach-Object {
        [pscustomobject]@{
            ReleaseId          = $_.id
            Version            = $_.version
            PublishedAt        = $(try { [datetime]$_.publishedAt } catch { [datetime]::MinValue })
            CompatibleVersions = @($_.compatibleVersions)
            Downloaded         = ($_.synchronizationStatus -eq 'DOWNLOADED')
        }
    } | Sort-Object PublishedAt)

    $script:FirmwareReleaseCache[$DeviceTypeId] = $releases
    return $releases
}

function Submit-FirmwareMassUpdate {
    <#
    .SYNOPSIS
        Reicht ein Firmware-Update fuer ein oder mehrere Geraete in EINEM
        Aufruf ein - echtes Batch-API.
    .DESCRIPTION
        WICHTIG: 'iectl device firmware update' kommt nie bis zur
        eigentlichen Einreichung - es ruft intern zuerst denselben defekten
        Endpunkt auf wie 'firmware list' (siehe Get-FirmwareReleases) und
        crasht dort (live bestaetigt: 11/11 Geraete fehlgeschlagen,
        serverseitig folgenlos, siehe update-status "no firmware update
        requests were submitted").

        Per Browser-Netzwerkmitschnitt (Portal-UI) den echten Weg gefunden:
            POST {baseUrl}/firmwaremanagement/api/v1/firmware/massUpdate
            Body: {"intervalTime":0,"content":[{"deviceId":..,"deviceName":..,"releaseId":..}, ...]}
        Die Portal-UI authentifiziert sich per Session-Cookie + CSRF-Header;
        unser Bearer-Token (aus 'iectl token fetch') genuegt aber ebenso -
        live verifiziert (202 Accepted ganz ohne Cookie/CSRF). CSRF-Schutz
        gilt offenbar nur fuer die cookie-authentifizierte Browser-Sitzung,
        nicht fuer Bearer-Token-Aufrufe.

        Ende-zu-Ende live verifiziert (18./19.09.2026): IEvD-XI erfolgreich
        von ievd-1.27.1-1-b auf ievd-1.28.1-2-b aktualisiert, beobachtete
        Zustandsfolge CREATED -> INSTALLING -> ACTIVATING -> ACTIVATED.
    #>
    param([Parameter(Mandatory)][object[]]$Items)  # je Item: DeviceId, DeviceName, ReleaseId

    $baseUrl  = Get-IemBaseUrl
    $token    = Get-IemBearerToken
    $headers  = @{ Authorization = "Bearer $token" }
    $skipCert = [bool]$env:EDGE_SKIP_TLS

    $body = [pscustomobject]@{
        intervalTime = 0
        content      = @($Items | ForEach-Object {
            [pscustomobject]@{ deviceId = $_.DeviceId; deviceName = $_.DeviceName; releaseId = $_.ReleaseId }
        })
    } | ConvertTo-Json -Depth 5 -Compress

    return Invoke-RestMethod -Uri "$baseUrl/firmwaremanagement/api/v1/firmware/massUpdate" -Method Post `
        -Headers $headers -Body $body -ContentType 'application/json' -SkipCertificateCheck:$skipCert -TimeoutSec 30
}

function Get-FirmwareUpdateInstance {
    <#
    .SYNOPSIS
        Liefert den neuesten Update-Status-Eintrag fuer ein Geraet.
    .DESCRIPTION
        GET {baseUrl}/firmwaremanagement/api/v1/firmware/massUpdate?deviceId=...
        - derselbe Endpunkt, den die Portal-UI zum Anzeigen des Fortschritts
        pollt. Relevantes Feld: 'instanceState' (live beobachtete Werte:
        CREATED, INSTALLING, ACTIVATING, ACTIVATED [Erfolg]; ein echter
        Fehlerzustand wurde noch nicht beobachtet).
    #>
    param([Parameter(Mandatory)][string]$DeviceId)

    $baseUrl  = Get-IemBaseUrl
    $token    = Get-IemBearerToken
    $headers  = @{ Authorization = "Bearer $token" }
    $skipCert = [bool]$env:EDGE_SKIP_TLS

    $resp = Invoke-RestMethod -Uri "$baseUrl/firmwaremanagement/api/v1/firmware/massUpdate?deviceId=$DeviceId&sort=instanceCreatedTime,scheduledExecutionTime,desc" `
        -Headers $headers -SkipCertificateCheck:$skipCert -TimeoutSec 30
    return @($resp.content | Sort-Object instanceCreatedTime -Descending)[0]
}

function Resolve-NextFirmwareStep {
    <#
    .SYNOPSIS
        Bestimmt fuer eine aktuelle Firmware-Version den naechsten Schritt.
    .DESCRIPTION
        Bewusste Vorgabe (Nutzeranforderung): es wird NIE direkt auf die
        neueste Version gesprungen, sondern immer nur der naechste Schritt
        in der chronologischen Reihenfolge angeboten - das verursacht laut
        Hersteller-Kompatibilitaetsangaben die wenigsten Inkompatibilitaeten.
        Ein Schritt wird zusaetzlich nur angeboten, wenn die Zielversion die
        aktuelle Version explizit in ihrer compatibleVersions-Liste fuehrt.
        Diese Eintraege sind Regex-Muster, keine exakten Strings (z.B.
        "ievd-1\.28\.1-2-a"), daher Musterabgleich statt -contains.
    #>
    param(
        [Parameter(Mandatory)][string]$CurrentVersion,
        [Parameter(Mandatory)][object[]]$Releases   # chronologisch aufsteigend, siehe Get-FirmwareReleases
    )

    $currentIdx = -1
    for ($i = 0; $i -lt $Releases.Count; $i++) {
        if ($Releases[$i].Version -eq $CurrentVersion) { $currentIdx = $i; break }
    }

    if ($currentIdx -eq -1) {
        return [pscustomobject]@{ NextRelease = $null; IsLatest = $false; Reason = "current version '$CurrentVersion' not found in the release catalog" }
    }
    if ($currentIdx -eq $Releases.Count - 1) {
        return [pscustomobject]@{ NextRelease = $null; IsLatest = $true; Reason = 'already on the newest known version' }
    }

    $next = $Releases[$currentIdx + 1]
    $isCompatible = $false
    foreach ($pattern in $next.CompatibleVersions) {
        try { if ($CurrentVersion -match "^$pattern$") { $isCompatible = $true; break } } catch { }
    }
    if (-not $isCompatible) {
        return [pscustomobject]@{ NextRelease = $null; IsLatest = $false; Reason = "next release '$($next.Version)' does not allow a direct step from '$CurrentVersion' per manufacturer data" }
    }

    return [pscustomobject]@{ NextRelease = $next; IsLatest = $false; Reason = $null }
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Firmware - Geraetedaten
# ─────────────────────────────────────────────────────────────────────────────

function Get-DeviceFirmwareInfo {
    <#
    .SYNOPSIS
        Ermittelt je Geraet die aktuelle Firmware-Version und den
        Geraetetyp - parallel, analog zu Get-DeviceHeartbeats.
    .DESCRIPTION
        Weder V1 noch V2 liefern die Firmware-Version in der Geraete-BULK-
        Liste mit (nur in den Einzelabrufen 'get-details'/'details'), daher
        ein Aufruf je Geraet.
    #>
    param([Parameter(Mandatory)][object[]]$Devices)

    $work = foreach ($d in $Devices) {
        [pscustomobject]@{
            DeviceId  = $d.DeviceId
            IectlArgs = [string[]](Get-ApiArgs -Op 'device.details' -P @{ DeviceId = $d.DeviceId })
        }
    }

    $results = $work | ForEach-Object -ThrottleLimit $script:MaxParallel -Parallel {
        $ErrorActionPreference = 'Stop'
        $item    = $_
        $version = $null
        $typeId  = $null
        $err     = $null

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName               = 'iectl'
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        foreach ($a in $item.IectlArgs) { $psi.ArgumentList.Add([string]$a) }

        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi
        try {
            [void]$proc.Start()
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $errTask = $proc.StandardError.ReadToEndAsync()
            if (-not $proc.WaitForExit(60000)) {
                try { $proc.Kill($true) } catch { }
                $err = 'Timeout nach 60s'
            }
            else {
                $stdout = $outTask.GetAwaiter().GetResult()
                $stderr = $errTask.GetAwaiter().GetResult()
                if ($proc.ExitCode -ne 0) {
                    $line = ($stderr -split "`r?`n" | Where-Object { $_ -match '^\s*Error:' } | Select-Object -First 1)
                    $err  = if ($line) { $line.Trim() } else { "ExitCode $($proc.ExitCode)" }
                }
                else {
                    $j = $stdout | ConvertFrom-Json
                    $d = if ($j.data) { $j.data } else { $j }
                    $version = if ($d.deviceVersion) { $d.deviceVersion } elseif ($d.version) { $d.version } else { $null }
                    $typeId  = if ($d.deviceTypeId)  { $d.deviceTypeId }  elseif ($d.typeId)  { $d.typeId }  else { $null }
                }
            }
        }
        catch { $err = $_.Exception.Message }
        finally { $proc.Dispose() }

        [pscustomobject]@{ DeviceId = $item.DeviceId; FirmwareVersion = $version; DeviceTypeId = $typeId; Error = $err }
    }

    foreach ($r in $results) {
        if ($r.Error) { Write-Log "Firmware-Info $($r.DeviceId): FEHLER - $($r.Error)" 'WARN' }
        else          { Write-Log "Firmware-Info $($r.DeviceId): Version=$($r.FirmwareVersion) Typ=$($r.DeviceTypeId)" 'INFO' }
    }
    return @($results)
}

function New-FirmwareDeviceRows {
    <#
        Baut Zeilen im GLEICHEN Format wie New-DeviceRows, damit
        Select-DevicesCheckbox unveraendert wiederverwendet werden kann -
        identische Geraeteauswahl-UI fuer Firmware wie fuer Apps.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Devices,
        [Parameter(Mandatory)][object[]]$LiveStates,
        [Parameter(Mandatory)][hashtable]$FirmwareInfo   # DeviceId -> Get-DeviceFirmwareInfo-Eintrag
    )

    $liveByDev = @{}
    foreach ($l in $LiveStates) { $liveByDev[$l.DeviceId] = $l }

    return @($Devices | ForEach-Object {
        $dev  = $_
        $live = $liveByDev[$dev.DeviceId]
        $fw   = $FirmwareInfo[$dev.DeviceId]

        $online = $(if ($live) { $live.OnlineState }  else { 'UNKNOWN' })
        $detail = $(if ($live) { $live.StatusDetail } else { 'no status determined' })

        $currentVersion = $(if ($fw -and $fw.FirmwareVersion) { $fw.FirmwareVersion } else { $null })
        $lockReason  = $null
        $actionText  = $null
        $nextRelease = $null
        $isUpToDate  = $false

        if (-not $fw -or $fw.Error) {
            $lockReason = "Firmware info not determinable: $(if ($fw) { $fw.Error } else { 'unknown' })"
            $actionText = '-'
        }
        elseif (-not $currentVersion) {
            $lockReason = 'current firmware version not determinable'
            $actionText = '-'
        }
        elseif (-not $fw.DeviceTypeId) {
            $lockReason = 'device type not determinable'
            $actionText = '-'
        }
        else {
            try {
                $releases = Get-FirmwareReleases -DeviceTypeId $fw.DeviceTypeId
                $step     = Resolve-NextFirmwareStep -CurrentVersion $currentVersion -Releases $releases
                if ($step.NextRelease) {
                    $nextRelease = $step.NextRelease
                    $actionText  = "Update $currentVersion -> $($nextRelease.Version)  (next step)"
                }
                else {
                    $lockReason = $step.Reason
                    $actionText = $step.Reason
                    $isUpToDate = $step.IsLatest
                }
            }
            catch {
                $lockReason = "Release lookup failed: $_"
                $actionText = $lockReason
            }
        }

        $statusText = "$online, $detail"

        [pscustomobject]@{
            DeviceName            = $dev.DeviceName
            DeviceId              = $dev.DeviceId
            OnlineState           = $online
            StatusDetail          = $detail
            InstalledVersion      = $(if ($currentVersion) { $currentVersion } else { '(unbekannt)' })
            IsUpToDate            = $isUpToDate
            IsDowngrade           = $false
            StatusText            = $statusText
            ActionText            = $actionText
            LockReason            = $lockReason
            IsLocked              = ($null -ne $lockReason)
            RequiresOfflineUnlock = ($online -ne 'ONLINE')
            NextRelease           = $nextRelease
        }
    })
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Firmware - Ausfuehrung
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-FirmwareUpdateBatch {
    <#
    .SYNOPSIS
        Reicht Firmware-Updates fuer EINEN Batch ein (echtes Batch-API, ein
        Aufruf fuer alle Geraete des Batches) und wartet auf Abschluss. Die
        Aufteilung in Batches a $script:BatchSize erfolgt in Invoke-StateFirmware.
    .DESCRIPTION
        Nutzt Submit-FirmwareMassUpdate/Get-FirmwareUpdateInstance (siehe
        dort) statt iectl - 'iectl device firmware update' kann auf diesem
        Build nie erfolgreich sein (interner Vorab-Aufruf an denselben
        defekten Endpunkt wie 'firmware list', live bestaetigt). Da hier nur
        noch einfache HTTP-Aufrufe noetig sind (kein iectl-Prozess-Spawning
        mehr), laeuft das Polling sequentiell im Hauptthread - fuer die
        ueblichen Batchgroessen voellig ausreichend schnell.

        Beobachtete Zustandsfolge (live, IEvD-XI): CREATED -> INSTALLING ->
        ACTIVATING -> ACTIVATED (Erfolg). Ein echter Fehlerzustand wurde
        noch nicht beobachtet; alles mit 'fail'/'error'/'cancel' wird
        defensiv als Fehlschlag gewertet.

        Geraete, die schon vor dem Start nicht sicher online waren, werden
        NICHT eingereicht (kein Job-Queueing wie bei Apps moeglich - ein
        Firmware-Flash braucht ein online Geraet).
    #>
    param(
        [Parameter(Mandatory)][object[]]$Rows,   # Zeilen aus New-FirmwareDeviceRows mit .NextRelease
        [string[]]$OfflineDeviceIds = @()
    )

    $offlineSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$OfflineDeviceIds)
    $skipped = @($Rows | Where-Object { $offlineSet.Contains($_.DeviceId) })
    $toRun   = @($Rows | Where-Object { -not $offlineSet.Contains($_.DeviceId) })

    foreach ($s in $skipped) {
        Write-Warn "$($s.DeviceName): device offline - firmware update NOT started (please retry after reconnecting)."
        Write-Log "$($s.DeviceName): Firmware-Update uebersprungen - Geraet offline." 'INFO'
    }

    if ($toRun.Count -eq 0) {
        return @($skipped | ForEach-Object {
            [pscustomobject]@{ DeviceName = $_.DeviceName; DeviceId = $_.DeviceId; Ok = $false; Skipped = $true; Error = 'Device offline - not started' }
        })
    }

    Write-Step "Submitting firmware update for $($toRun.Count) device(s)..."
    Write-Warn 'The devices restart during the update - a brief connection loss is normal.'

    $submitItems = @($toRun | ForEach-Object {
        [pscustomobject]@{ DeviceId = $_.DeviceId; DeviceName = $_.DeviceName; ReleaseId = $_.NextRelease.ReleaseId }
    })

    try {
        [void](Submit-FirmwareMassUpdate -Items $submitItems)
        Write-Success "Batch submitted ($($submitItems.Count) device(s))."
        Write-Log "Firmware-massUpdate eingereicht fuer: $(($submitItems.DeviceName) -join ', ')" 'OK'
    }
    catch {
        Write-Err "Firmware batch could not be submitted: $_"
        $results = @($toRun | ForEach-Object {
            [pscustomobject]@{ DeviceName = $_.DeviceName; DeviceId = $_.DeviceId; Ok = $false; Skipped = $false; Error = "Submission failed: $_" }
        }) + @($skipped | ForEach-Object {
            [pscustomobject]@{ DeviceName = $_.DeviceName; DeviceId = $_.DeviceId; Ok = $false; Skipped = $true; Error = 'Device offline - not started' }
        })
        foreach ($r in $results) { if (-not $r.Skipped) { Write-Err "$($r.DeviceName): $($r.Error)" } }
        return @($results)
    }

    $pollIntervalSec = 15
    $maxTotalWaitSec = 1800   # 30 Minuten - Firmware-Updates inkl. Neustart dauern deutlich laenger als App-Jobs
    $pending = [ordered]@{}
    foreach ($r in $toRun) { $pending[$r.DeviceId] = $r.DeviceName }
    $results = @()
    $elapsed = 0

    while ($pending.Count -gt 0 -and $elapsed -lt $maxTotalWaitSec) {
        Start-Sleep -Seconds $pollIntervalSec
        $elapsed += $pollIntervalSec
        Write-Host "  ... still waiting for firmware update(s) ($($pending.Count) open), waited (${elapsed}s/max. ${maxTotalWaitSec}s)..." -ForegroundColor DarkGray

        foreach ($devId in @($pending.Keys)) {
            $devName = $pending[$devId]
            $inst = $null
            try { $inst = Get-FirmwareUpdateInstance -DeviceId $devId }
            catch { Write-Log "${devName}: Status-Abfrage fehlgeschlagen (evtl. Neustart, ignoriert): $_" 'WARN'; continue }
            if (-not $inst) { continue }

            $state = [string]$inst.instanceState
            if ($state -eq 'ACTIVATED') {
                $results += [pscustomobject]@{ DeviceName = $devName; DeviceId = $devId; Ok = $true; Skipped = $false; Error = $null; ElapsedSec = $elapsed; FinalState = $state }
                $pending.Remove($devId)
            }
            elseif ($state -match '(?i)fail|error|cancel') {
                $results += [pscustomobject]@{ DeviceName = $devName; DeviceId = $devId; Ok = $false; Skipped = $false; Error = "Firmware update failed (status: $state)"; ElapsedSec = $elapsed; FinalState = $state }
                $pending.Remove($devId)
            }
            # sonst (CREATED/INSTALLING/ACTIVATING/...): weiter pollen.
        }
    }

    foreach ($devId in @($pending.Keys)) {
        $results += [pscustomobject]@{ DeviceName = $pending[$devId]; DeviceId = $devId; Ok = $false; Skipped = $false; Error = "Not completed after ${maxTotalWaitSec}s"; ElapsedSec = $elapsed }
    }
    $results += @($skipped | ForEach-Object {
        [pscustomobject]@{ DeviceName = $_.DeviceName; DeviceId = $_.DeviceId; Ok = $false; Skipped = $true; Error = 'Device offline - not started' }
    })

    foreach ($r in ($results | Sort-Object DeviceName)) {
        if ($r.Ok) {
            Write-Success "$($r.DeviceName): firmware update completed (status: $($r.FinalState))."
            Write-Log "$($r.DeviceName): Firmware-Update OK (Status: $($r.FinalState))" 'OK'
        }
        elseif ($r.Skipped) {
            Write-Log "$($r.DeviceName): Firmware-Update uebersprungen (offline)." 'INFO'
        }
        else {
            Write-Err "$($r.DeviceName): $($r.Error)"
            Write-Log "$($r.DeviceName): Firmware-Update FEHLER: $($r.Error)" 'ERROR'
        }
    }
    return @($results)
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: State - Firmware
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-StateFirmware {
    <#
        Deckt bewusst NUR die Operation 'update' ab (kein Install/Uninstall/
        Downgrade - fuer Firmware gibt es das nicht). Zielversion wird je
        Geraet automatisch als naechster kompatibler Schritt bestimmt (siehe
        Resolve-NextFirmwareStep), nie ein Sprung auf die neueste Version.
        Geraeteauswahl nutzt bewusst dieselbe UI wie der App-Workflow
        (Select-DevicesCheckbox unveraendert wiederverwendet).
    #>
    Write-Header 'Firmware Update'
    Write-LogSeparator 'Firmware'

    Write-Step 'Loading edge devices...'
    try {
        $devices = Get-AllDevices
    }
    catch {
        Write-Err "Device list not reachable: $_"
        return 'MODE'
    }
    if ($devices.Count -eq 0) {
        Write-Warn 'No edge devices found.'
        return 'MODE'
    }
    Write-Success "$($devices.Count) device(s) found."

    Write-Step 'Determining live status...'
    $liveStates = Get-DeviceLiveState -Devices $devices

    Write-Step "Determining current firmware version per device (max. $($script:MaxParallel) parallel)..."
    $fwInfoList = Get-DeviceFirmwareInfo -Devices $devices
    $fwInfo = @{}
    foreach ($f in $fwInfoList) { $fwInfo[$f.DeviceId] = $f }

    Write-Step 'Determining available firmware releases per device type...'
    try {
        $rows = New-FirmwareDeviceRows -Devices $devices -LiveStates $liveStates -FirmwareInfo $fwInfo
    }
    catch {
        Write-Err "Firmware release lookup failed: $_"
        return 'MODE'
    }

    Write-Host ''
    Write-Host ("  {0,-22} | {1,-10} | {2,-16} | {3}" -f 'Device', 'Status', 'Firmware', 'Next step/reason') -ForegroundColor White
    Write-Host ('  ' + ('-' * 108)) -ForegroundColor DarkGray
    foreach ($r in $rows) {
        $color = switch ($r.OnlineState) {
            'ONLINE'  { if ($r.IsLocked) { 'DarkGray' } else { 'White' } }
            'OFFLINE' { 'Red' }
            default   { 'DarkYellow' }
        }
        Write-Host ("  {0,-22} | {1,-10} | {2,-16} | {3}" -f $r.DeviceName, $r.OnlineState, $r.InstalledVersion, $r.ActionText) -ForegroundColor $color
        Write-Log ("{0} | {1} | Firmware={2} | {3}" -f $r.DeviceName, $r.OnlineState, $r.InstalledVersion, $r.ActionText) 'INFO'
    }
    Write-Host ''
    Write-Info 'It deliberately never jumps to the newest version - always only the next compatible step, to avoid incompatibilities.' -Color DarkGray

    $actionable = @($rows | Where-Object { -not $_.IsLocked })
    if ($actionable.Count -eq 0) {
        Write-Success 'No device needs a firmware update.'
        Write-Host ''
        Read-Host 'Press Enter to return to mode selection' | Out-Null
        return 'MODE'
    }

    Write-Host ''
    Read-Host 'Press Enter to go to device selection' | Out-Null

    $title    = 'Target devices for firmware update (Q = back to mode selection)'
    $selected = $null
    while ($true) {
        $sel = Select-DevicesCheckbox -Items $rows -Title $title
        if ($null -eq $sel) {
            Write-Log 'Firmware-Geraeteauswahl mit Q verlassen -> zurueck zur Modusauswahl.' 'INFO'
            return 'MODE'
        }
        if ($sel.Count -gt 0) { $selected = $sel; break }
        Write-Warn 'No device selected. Please select at least one, or go back with Q.'
        Start-Sleep -Seconds 1
    }

    Write-Header 'Firmware Update - Confirmation'
    Write-Host "  Devices: $($selected.Count)" -ForegroundColor White
    Write-Host ("  Batches: {0} of max. {1} devices (one after another)" -f [math]::Ceiling($selected.Count / $script:BatchSize), $script:BatchSize) -ForegroundColor White
    Write-Host ''
    foreach ($d in $selected) {
        $color = switch ($d.OnlineState) { 'ONLINE' { 'Gray' } 'OFFLINE' { 'Red' } default { 'DarkYellow' } }
        Write-Host ("    - {0,-22} [{1,-9}] {2}" -f $d.DeviceName, $d.OnlineState, $d.ActionText) -ForegroundColor $color
    }
    Write-Host ''
    $offline = @($selected | Where-Object { $_.OnlineState -ne 'ONLINE' })
    if ($offline.Count -gt 0) {
        Write-Host "  NOTE: $($offline.Count) device(s) are not reliably online - the update will NOT be started for these (unlike apps, there is no automatic catch-up on reconnect)." -ForegroundColor Yellow
        Write-Host ''
    }
    Write-Warn 'The devices will restart during the update.'
    $confirm = (Read-Host 'Run the firmware update now? [y/N]').Trim()
    Write-Log "Firmware-Ausfuehrungsbestaetigung: '$confirm'" 'INFO'
    if ($confirm -notmatch '^[jJyY]') {
        Write-Warn 'Aborted.'
        return 'MODE'
    }

    Write-Header 'Firmware update running'
    $offlineIds = @($selected | Where-Object { $_.OnlineState -ne 'ONLINE' } | ForEach-Object { $_.DeviceId })
    $batches = Split-IntoBatches -Items $selected
    Write-Info ("{0} device(s) in {1} batch(es) of max. {2}." -f `
        $selected.Count, $batches.Count, $script:BatchSize) -Color Cyan

    # Batches run one after another: the next one starts only once the
    # previous one has finished - so never more than one batch is rebooting.
    $results = @()
    $batchNo = 0
    foreach ($batch in $batches) {
        $batchNo++
        Write-Header "Firmware batch $batchNo/$($batches.Count)  ($($batch.Count) devices)"
        Write-Log "Firmware-Batch $batchNo/$($batches.Count): $(($batch.DeviceName) -join ', ')" 'INFO'
        $results += @(Invoke-FirmwareUpdateBatch -Rows $batch -OfflineDeviceIds $offlineIds)
    }

    Write-Header 'Firmware Update - Result'
    $okCount = @($results | Where-Object Ok).Count
    Write-Host ("  {0} of {1} device(s) updated successfully." -f $okCount, $selected.Count) -ForegroundColor White
    Write-Host ''
    Read-Host 'Press Enter to return to mode selection' | Out-Null
    return 'MODE'
}

# ─────────────────────────────────────────────────────────────────────────────
# REGION: Einstieg
# ─────────────────────────────────────────────────────────────────────────────

Write-Header "IEM App Installer $($script:ScriptVersion)"

if (-not (Get-Command iectl -ErrorAction SilentlyContinue)) {
    Write-Host '[X]  iectl not found in PATH.' -ForegroundColor Red
    exit 1
}

# API-Version bestimmen
if (-not $ApiVersion) {
    Write-Host '  Which IEM API should be used?' -ForegroundColor White
    Write-Host '  [1] V1  - iectl iem      (fallback)'
    Write-Host '  [2] V2  - iectl iem-v2   (recommended for automation)'
    Write-Host ''
    while (-not $ApiVersion) {
        $sel = (Read-Host 'Choose API (1/2, q = exit)').Trim()
        switch ($sel) {
            '1' { $ApiVersion = 'V1' }
            '2' { $ApiVersion = 'V2' }
            default {
                if ($sel -match '^[qQ]$') { exit 0 }
                Write-Host '[!]  Please enter 1, 2 or q.' -ForegroundColor Magenta
            }
        }
    }
}

$script:Api = New-ApiProfile -Version $ApiVersion

Initialize-Log
Write-Success "iectl found. API mode: $($script:Api.Version) ($($script:Api.Root))"
Write-Info "Batch size: max. $($script:BatchSize) devices per batch (app and firmware jobs)." -Color Cyan
Write-Info 'Adjustable in Start-EN.cmd (line "set BATCHSIZE=10", allowed 1-100) or via parameter -BatchSize.' -Color DarkGray
Write-Log "Start | API=$($script:Api.Version) | BatchSize=$($script:BatchSize) | MaxParallel=$($script:MaxParallel) | JobWaitTimeout=$($script:JobWaitTimeoutSec)s" 'INFO'

# ─────────────────────────────────────────────────────────────────────────────
# REGION: State-Machine
#
# Ersetzt die Selbst-Neustarts der Vorversion. 'q' geht immer genau einen
# Schritt zurueck, alles laeuft in einem einzigen Prozess.
# ─────────────────────────────────────────────────────────────────────────────

$state = 'CONFIG'
try {
    while ($state -ne 'EXIT') {
        Write-Log "State -> $state" 'INFO'
        $stateResult = switch ($state) {
            'CONFIG'   { Invoke-StateConfig }
            'MODE'     { Invoke-StateMode }
            'APP'      { Invoke-StateApp }
            'VERSION'  { Invoke-StateVersion }
            'DEVICES'  { Invoke-StateDevices }
            'CONFIRM'  { Invoke-StateConfirm }
            'EXECUTE'  { Invoke-StateExecute }
            'VERIFY'   { Invoke-StateVerify }
            'FIRMWARE' { Invoke-StateFirmware }
            default    {
                Write-Err "Unknown state '$state' - aborting."
                'EXIT'
            }
        }
        # Absicherung: Ein State-Handler soll per Konvention genau EINEN
        # Statusnamen liefern. Falls doch einmal Ausgabe durchsickert (z.B.
        # ein nicht abgefangener externer Prozessaufruf), landet hier sonst
        # ein vielelementiges Array statt eines Strings - das wuerde beim
        # naechsten switch JEDES Element einzeln durch den
        # "Unbekannter Zustand"-Zweig laufen lassen (live beobachtet: ca.
        # 20 Wiederholungen derselben Meldung). Nur das letzte Element zaehlt.
        $stateArr = @($stateResult)
        if ($stateArr.Count -gt 1) {
            Write-Log "State-Handler fuer '$state' lieferte $($stateArr.Count) Ausgabe-Objekte statt einem - verwende nur das letzte." 'WARN'
        }
        $state = [string]$stateArr[-1]
    }
}
catch {
    Write-Err "Unhandled error: $($_.Exception.Message)"
    Write-Log "STACK: $($_.ScriptStackTrace)" 'ERROR'
}
finally {
    Write-Header 'Finished'
    if ($script:LogFile) {
        Write-Host '  Log file' -ForegroundColor DarkGray
        Write-Host "  $script:LogFile" -ForegroundColor White
        Write-Host ''
    }
}
