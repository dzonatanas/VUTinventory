#Requires -Version 5.1
<#
.SYNOPSIS
    Manual verification of the review-fixes branch on a real Windows machine (not part of the PR).

.DESCRIPTION
    Runs Register-SnipeAsset.ps1 in child Windows PowerShell 5.1 processes and records the result
    of every check in windows-checks-result.txt next to this repo.

    NEVER writes to Snipe-IT: every run uses -DryRun, or exits before any API call
    (and then also points -SnipeUrl at 127.0.0.1:9 as a safety net).
    Read-only API calls use the token from snipeit.token; the token is never printed.

    Side effects on this machine: lines appended to C:\ProgramData\SnipeIT\register.log,
    wallpaper preview PNG in %TEMP%, PSScriptAnalyzer/Pester 5 installed for the current user.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Invoke-WindowsChecks.ps1
#>
[CmdletBinding()]
param(
    [string]$SnipeUrl = 'https://inventorius.liepu27.lt',
    [switch]$SkipApi                    # only the offline checks (A*)
)

$ErrorActionPreference = 'Stop'
$repo      = Split-Path $PSScriptRoot
$target    = Join-Path $repo 'Register-SnipeAsset.ps1'
$resultLog = Join-Path $repo 'windows-checks-result.txt'
$auditLog  = "$env:ProgramData\SnipeIT\register.log"
$noApi     = 'https://127.0.0.1:9'       # nothing listens there
$testSerial = 'VUTCHECK-' + [guid]::NewGuid().ToString('N').Substring(0, 8).ToUpper()
$results   = New-Object System.Collections.Generic.List[string]

function Add-Line { param([string]$Text) $results.Add($Text); Write-Host $Text }

function Get-AuditLineCount {
    if (Test-Path $auditLog) { @(Get-Content $auditLog).Count } else { 0 }
}

# Runs the script in a child powershell.exe; checks "one JSON line on stdout" + expected exit code
function Invoke-Case {
    param(
        [string]$Id, [string]$Title, [string[]]$ScriptArgs, [int[]]$ExpectExit,
        [scriptblock]$Check,               # gets the parsed JSON, returns '' if OK or a failure text
        [string]$ScriptPath = $target
    )
    $errFile = [IO.Path]::GetTempFileName()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $stdout = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @ScriptArgs 2> $errFile)
    $code = $LASTEXITCODE
    $sw.Stop()
    $stderr = (Get-Content $errFile -Raw); Remove-Item $errFile -ErrorAction SilentlyContinue

    $problems = @()
    if ($stdout.Count -ne 1) { $problems += "expected 1 stdout line, got $($stdout.Count)" }
    $json = $null
    try { $json = ($stdout -join "`n") | ConvertFrom-Json } catch { $problems += 'stdout is not valid JSON' }
    if ($code -notin $ExpectExit) { $problems += "exit $code, expected $($ExpectExit -join '/')" }
    if ($json -and $Check) { $msg = & $Check $json; if ($msg) { $problems += $msg } }

    $verdict = if ($problems) { 'FAIL' } else { 'PASS' }
    Add-Line ("[{0}] {1} {2} (exit {3}, {4:N1}s)" -f $verdict, $Id, $Title, $code, $sw.Elapsed.TotalSeconds)
    foreach ($p in $problems) { Add-Line "       problem: $p" }
    Add-Line "       stdout: $($stdout -join ' | ')"
    if ($stderr) { Add-Line "       stderr: $($stderr.Trim())" }
    [pscustomobject]@{ Json = $json; Exit = $code; Seconds = $sw.Elapsed.TotalSeconds }
}

Add-Line "Windows checks for review-fixes  $(Get-Date -Format s)"
$commit = 'unknown'
try { $commit = git -C $repo rev-parse --short HEAD } catch { Write-Verbose 'git not available' }
Add-Line "PS $($PSVersionTable.PSVersion)  OS $((Get-CimInstance Win32_OperatingSystem).Caption)  commit $commit"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Line "Admin: $isAdmin   test serial: $testSerial"
Add-Line ''

# ---------- A1/A2: parse, analyzer, Pester under Windows PowerShell 5.1 ----------
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$parseErrors) | Out-Null
if ($parseErrors) { Add-Line "[FAIL] A1 parse: $($parseErrors -join '; ')" } else { Add-Line '[PASS] A1 script parses in PS 5.1' }

try {
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
    }
    $findings = @(Invoke-ScriptAnalyzer -Path $target) + @(Invoke-ScriptAnalyzer -Path (Join-Path $repo 'tests') -Recurse)
    $errs = @($findings | Where-Object Severity -eq 'Error')
    Add-Line ("[{0}] A1 PSScriptAnalyzer: {1} findings, {2} of severity Error" -f
        $(if ($errs) { 'FAIL' } else { 'PASS' }), $findings.Count, $errs.Count)
    foreach ($f in $findings) { Add-Line "       $($f.Severity) $($f.RuleName) $($f.ScriptName):$($f.Line)" }
} catch { Add-Line "[SKIP] A1 PSScriptAnalyzer not available: $($_.Exception.Message)" }

try {
    if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.5.0' })) {
        Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
    }
    $pesterOut = & powershell.exe -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; `$c = New-PesterConfiguration; `$c.Run.Path = '$repo\tests'; `$c.Run.PassThru = `$true; `$c.Output.Verbosity = 'None'; `$r = Invoke-Pester -Configuration `$c; '{0} passed, {1} failed' -f `$r.PassedCount, `$r.FailedCount; `$r.Failed | ForEach-Object { 'FAILED: ' + `$_.ExpandedPath + ' :: ' + `$_.ErrorRecord }"
    $failed = ($pesterOut | Select-Object -First 1) -notmatch ' 0 failed$'
    Add-Line ("[{0}] A2 Pester (PS 5.1): {1}" -f $(if ($failed) { 'FAIL' } else { 'PASS' }), ($pesterOut -join ' | '))
} catch { Add-Line "[SKIP] A2 Pester not available: $($_.Exception.Message)" }
Add-Line ''

# ---------- A3: -Serial without -DryRun ----------
$logBefore = Get-AuditLineCount
Invoke-Case A3 '-Serial without -DryRun is rejected before any API call' `
    @('-Serial', 'X', '-SnipeUrl', $noApi, '-NoWallpaper') @(1) `
    { param($j) if ($j.message -notlike '*only allowed together with -DryRun*') { "message: $($j.message)" } } | Out-Null

# ---------- A4: empty token file ----------
$tmpDir = Join-Path $env:TEMP "vutcheck-$testSerial"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
Copy-Item $target $tmpDir
Set-Content -Path (Join-Path $tmpDir 'snipeit.token') -Value '' -NoNewline
$savedEnvToken = $env:SNIPEIT_TOKEN; $env:SNIPEIT_TOKEN = $null
try {
    Invoke-Case A4 'empty snipeit.token -> JSON error, exit 1' `
        @('-DryRun', '-SnipeUrl', $noApi, '-NoWallpaper') @(1) `
        { param($j) if ($j.message -notlike 'API token missing*') { "message: $($j.message)" } } `
        -ScriptPath (Join-Path $tmpDir 'Register-SnipeAsset.ps1') | Out-Null
} finally { $env:SNIPEIT_TOKEN = $savedEnvToken; Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

# ---------- A5: TLS ----------
$tls = & powershell.exe -NoProfile -Command "'before: ' + [Net.ServicePointManager]::SecurityProtocol; & '$target' -Serial X -SnipeUrl $noApi -NoWallpaper | Out-Null; 'after: ' + [Net.ServicePointManager]::SecurityProtocol"
Add-Line "[INFO] A5 TLS $($tls -join ', ')  (expect: unchanged if SystemDefault, otherwise Tls12 added, nothing removed)"

# ---------- A6: retry / error body ----------
$r = Invoke-Case A6a 'unreachable host: GET retried 3x then network error' `
    @('-DryRun', '-Serial', $testSerial, '-SnipeUrl', $noApi, '-NoWallpaper') @(1) `
    { param($j) if ($j.message -notlike 'Snipe-IT network error*') { "message: $($j.message)" } }
if ($r.Seconds -lt 6) { Add-Line "       problem: finished in $([int]$r.Seconds)s, expected >= 6s (2s + 4s backoff)" }

if (-not $SkipApi) {
    $r = Invoke-Case A6b 'wrong path (4xx): no retry, HTTP status + body in message' `
        @('-DryRun', '-Serial', $testSerial, '-SnipeUrl', "$SnipeUrl/vutcheck-404", '-NoWallpaper') @(1) `
        { param($j) if ($j.message -notmatch '^Snipe-IT HTTP 4\d\d ') { "message: $($j.message)" } }
    if ($r.Seconds -gt 5) { Add-Line "       problem: took $([int]$r.Seconds)s - looks like it retried" }
}

# ---------- A7: audit log ----------
$logAfter = Get-AuditLineCount
Add-Line ("[{0}] A7 audit log: {1} new lines in {2} (expected >= 3)" -f
    $(if ($logAfter - $logBefore -ge 3) { 'PASS' } else { 'FAIL' }), ($logAfter - $logBefore), $auditLog)
if (Test-Path $auditLog) { Add-Line "       last line: $(Get-Content $auditLog -Tail 1)" }
if (Test-Path $auditLog) {
    $lock = [IO.File]::Open($auditLog, 'Open', 'ReadWrite', 'None')
    try {
        Invoke-Case A7b 'locked log file: stdout and exit code unchanged' `
            @('-Serial', 'X', '-SnipeUrl', $noApi, '-NoWallpaper') @(1) `
            { param($j) if ($j.message -notlike '*only allowed together with -DryRun*') { "message: $($j.message)" } } | Out-Null
    } finally { $lock.Dispose() }
}
Add-Line ''

# ---------- A8: disks ----------
$ast = [Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$null)
foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($fn.Name -in 'Test-InternalDisk', 'Get-DiskTypeLabel', 'Test-JunkSerial', 'Get-LaptopModelString') {
        . ([scriptblock]::Create($fn.Extent.Text))
    }
}
Add-Line '[INFO] A8 Win32_DiskDrive:'
$fixedIds = @()
foreach ($d in Get-CimInstance Win32_DiskDrive) {
    Add-Line "       Index=$($d.Index) Model='$($d.Model)' MediaType='$($d.MediaType)' Interface=$($d.InterfaceType) Size=$([math]::Round($d.Size / 1e9))GB"
    if ($d.MediaType -eq 'Fixed hard disk media') { $fixedIds += "$($d.Index)" }
}
Add-Line '[INFO] A8 Get-PhysicalDisk -> script decision:'
foreach ($d in Get-PhysicalDisk) {
    $keep  = Test-InternalDisk -BusType "$($d.BusType)" -Size $d.Size -IsFixedMedia ("$($d.DeviceId)" -in $fixedIds)
    $label = Get-DiskTypeLabel -BusType "$($d.BusType)" -MediaType "$($d.MediaType)" -Name "$($d.FriendlyName) $($d.Model)"
    Add-Line "       DeviceId=$($d.DeviceId) FriendlyName='$($d.FriendlyName)' BusType=$($d.BusType) MediaType=$($d.MediaType) Size=$([math]::Round($d.Size / 1e9))GB -> keep=$keep label='$label'"
}
$cs = Get-CimInstance Win32_ComputerSystem; $csp = Get-CimInstance Win32_ComputerSystemProduct
Add-Line "[INFO] A8 laptop model: '$(Get-LaptopModelString -Manufacturer $cs.Manufacturer -Model $cs.Model -Version $csp.Version -Sku $cs.SystemSKUNumber)'  BIOS serial junk: $(Test-JunkSerial "$((Get-CimInstance Win32_BIOS).SerialNumber)".Trim())"
Add-Line ''

# ---------- B: read-only checks against Snipe-IT ----------
if ($SkipApi) { Add-Line '[SKIP] B* (-SkipApi)' }
else {
    $tokenFile = Join-Path $repo 'snipeit.token'
    $token = $env:SNIPEIT_TOKEN
    if (-not $token -and (Test-Path $tokenFile)) { $token = "$(Get-Content $tokenFile -Raw)".Trim() }
    if (-not $token) { Add-Line '[SKIP] B* no token (snipeit.token or env:SNIPEIT_TOKEN)' }
    else {
        $api = $SnipeUrl.TrimEnd('/') + '/api/v1'
        $h   = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
        $proto = [Net.ServicePointManager]::SecurityProtocol
        if ([int]$proto -ne 0) { [Net.ServicePointManager]::SecurityProtocol = $proto -bor [Net.SecurityProtocolType]::Tls12 }
        function Get-Api { param([string]$Path) Invoke-RestMethod -Uri "$api$Path" -Headers $h -TimeoutSec 30 }

        try {
            $v = Get-Api '/version'
            Add-Line "[INFO] B0 Snipe-IT version: $($v | ConvertTo-Json -Compress)"
        } catch { Add-Line "[INFO] B0 /version failed: $($_.Exception.Message)" }

        # B1: raw not-found response shape
        try {
            $nf = Get-Api "/hardware/byserial/$testSerial"
            Add-Line "[INFO] B1 raw byserial not-found response: $($nf | ConvertTo-Json -Compress)"
            $ok = $nf.status -eq 'error' -and $null -eq $nf.payload -and $nf.messages -is [string]
            Add-Line ("[{0}] B1 not-found shape matches what R3 expects" -f $(if ($ok) { 'PASS' } else { 'FAIL' }))
        } catch { Add-Line "[FAIL] B1 byserial call failed: $($_.Exception.Message)" }

        # B3/B4: status label and model fieldset as the API returns them
        try {
            $sl = Get-Api "/statuslabels?search=$([uri]::EscapeDataString('Ready to Deploy'))"
            Add-Line "[INFO] B3 status labels matching 'Ready to Deploy': $(($sl.rows | ForEach-Object { "id=$($_.id) name='$($_.name)' type=$($_.type)" }) -join '; ')"
        } catch { Add-Line "[FAIL] B3 statuslabels call failed (Status Labels view permission?): $($_.Exception.Message)" }
        try {
            $md = Get-Api "/models?search=$([uri]::EscapeDataString('VUT laptop'))"
            foreach ($m in $md.rows) {
                Add-Line "[INFO] B4 model id=$($m.id) name='$($m.name)' fieldset=$($m.fieldset | ConvertTo-Json -Compress)"
                Add-Line "       default_fieldset_values columns: $((@($m.default_fieldset_values) | ForEach-Object { $_.db_column_name }) -join ', ')"
            }
            if (-not $md.rows) { Add-Line "[INFO] B4 no model 'VUT laptop' on this instance" }
        } catch { Add-Line "[FAIL] B4 models call failed: $($_.Exception.Message)" }
        Add-Line ''

        # Full dry runs through the script
        Invoke-Case B1b 'dry run, serial not in Snipe-IT -> dryrun, exit 0 (R3, R6, R12, R7 notes)' `
            @('-DryRun', '-Serial', $testSerial) @(0) `
            { param($j) if ($j.result -ne 'dryrun') { "result: $($j.result) $($j.message)" }
                        elseif ($j.body.notes -notlike 'Registered by Register-SnipeAsset.ps1 v*') { 'notes missing' }
                        elseif (-not ($j.body.status_id -gt 0)) { 'status_id not resolved' } } | Out-Null

        Invoke-Case B1c 'dry run with this machine''s real BIOS serial -> dryrun (0) or exists (2)' `
            @('-DryRun') @(0, 2) $null | Out-Null

        try {
            $hw = Get-Api '/hardware?limit=50&sort=id&order=asc'
            $known = $hw.rows | Where-Object { $_.serial } | Select-Object -First 1
            if ($known) {
                $knownSerial = [Net.WebUtility]::HtmlDecode($known.serial)
                Invoke-Case B2 "dry run with existing serial -> exists, exit 2, tag $($known.asset_tag)" `
                    @('-DryRun', '-Serial', $knownSerial, '-NoWallpaper') @(2) `
                    { param($j) if ($j.asset_tag -ne [Net.WebUtility]::HtmlDecode($known.asset_tag)) { "asset_tag: $($j.asset_tag)" } } | Out-Null
            } else { Add-Line '[SKIP] B2 no asset with a serial on the instance' }
        } catch { Add-Line "[FAIL] B2 hardware list failed: $($_.Exception.Message)" }

        Invoke-Case B3b 'unknown -StatusName -> exit 1' `
            @('-DryRun', '-Serial', $testSerial, '-StatusName', 'No such label VUTCHECK', '-NoWallpaper') @(1) `
            { param($j) if ($j.message -notlike "Status label 'No such label VUTCHECK' not found*") { "message: $($j.message)" } } | Out-Null

        Invoke-Case B4b 'custom field not in fieldset -> exit 1 listing it' `
            @('-DryRun', '-Serial', $testSerial, '-FieldCpu', '_snipeit_vutcheck_999', '-NoWallpaper') @(1) `
            { param($j) if ($j.message -notlike '*lacks custom fields: _snipeit_vutcheck_999*') { "message: $($j.message)" } } | Out-Null
    }
}

Add-Line ''
Add-Line "Done. Send back: $resultLog"
$results | Set-Content -Path $resultLog -Encoding UTF8
