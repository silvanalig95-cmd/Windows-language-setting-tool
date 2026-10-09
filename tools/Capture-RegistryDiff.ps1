#Requires -Version 5.1
<#
.SYNOPSIS
    VM-ONLY development tool: determines empirically which registry keys/values the language recipe
    (and Microsoft's own "copy to welcome screen/new users") write, by diffing the registry before
    and after. CHANGES LANGUAGE SETTINGS - run it only in a test VM or Windows Sandbox.

.DESCRIPTION
    Scenarios
      Recipe                     Run as the test user (no elevation needed). Applies the recipe exactly as
                                 LanguageProfile.ps1 does inside a signed-in user's session (same worker code)
                                 and diffs HKCU (full) and HKU\.DEFAULT.
      RecipeAsSystem             Elevated. Runs the same worker as SYSTEM through a one-time scheduled task
                                 (this is how the tool writes the lock screen) and diffs HKU\.DEFAULT,
                                 S-1-5-19, S-1-5-20 and HKLM\SYSTEM\CurrentControlSet\Control.
      CopyToSystem               Elevated, in an account that already has the target settings (run the
                                 Recipe scenario in that account first). Runs Microsoft's copy:
                                 Windows 11: Copy-UserInternationalSettingsToSystem -WelcomeScreen -NewUser
                                 Windows 10: control.exe intl.cpl,,/f:<xml>
                                 and diffs .DEFAULT, S-1-5-19, S-1-5-20, the Default profile hive and HKLM.
                                 Used to check that the tool's direct writes cover everything Windows writes.
      SystemPreferredUILanguage  Elevated. Diffs HKLM + .DEFAULT around Set-SystemPreferredUILanguage.
      Snapshot / Compare         Manual: -Scenario Snapshot -Name before ... (do something, e.g. in Settings)
                                 ... -Scenario Snapshot -Name after; then -Scenario Compare -Before <file> -After <file>.

    Output: C:\Users\Public\Documents\LanguageProfile-Diff (same folder for every account), unless -OutDir
    is given. Per run: *_diff.txt (added/removed/changed values), *_keys.txt (keys touched), the raw
    *_before.txt/*_after.txt dumps and a *_transcript.txt with everything that was printed (also errors).
    Please send the *_diff.txt, *_keys.txt and *_transcript.txt files back.

    Easiest: double-click tools\Capture-RegistryDiff.cmd and pick the scenario from the menu. Scenarios that
    need administrator rights ask for elevation themselves. The window stays open at the end.

.EXAMPLE
    # as the test user
    powershell -ExecutionPolicy Bypass -File .\tools\Capture-RegistryDiff.ps1 -Scenario Recipe
.EXAMPLE
    # elevated
    powershell -ExecutionPolicy Bypass -File .\tools\Capture-RegistryDiff.ps1 -Scenario RecipeAsSystem
#>
[CmdletBinding()]
param(
    [ValidateSet('', 'Recipe', 'RecipeAsSystem', 'CopyToSystem', 'SystemPreferredUILanguage', 'Snapshot', 'Compare')][string]$Scenario = '',
    [string]$DisplayLanguage = 'en-US',
    [string]$RegionalFormat = 'de-CH',
    [int]$GeoId = 223,
    [string[]]$Keyboard = @('00000807'),
    [string]$OutDir = (Join-Path $env:PUBLIC 'Documents\LanguageProfile-Diff'),
    [string]$Name = 'snapshot',
    [string]$Before,
    [string]$After,
    [switch]$IncludeNoise,
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'

function Write-Step([string]$Text, [string]$Color = 'Cyan') { Write-Host ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Text) -ForegroundColor $Color }
function Wait-Close {
    if ($NoPause) { return }
    try { [void](Read-Host 'Press Enter to close this window') } catch { }
}

if ($PSVersionTable.PSEdition -ne 'Desktop') { Write-Host 'Run this in Windows PowerShell 5.1 (powershell.exe), not PowerShell 7.' -ForegroundColor Red; Wait-Close; exit 1 }
$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($me)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $Scenario) {
    Write-Host ''
    Write-Host 'Language Profile - registry diff (VM ONLY: this changes language settings)' -ForegroundColor Yellow
    Write-Host "Running as $($me.Name)$(if ($isAdmin) { ' (elevated)' } else { ' (not elevated)' })"
    Write-Host ''
    Write-Host '  1  Recipe                     run as the TEST USER, not elevated'
    Write-Host '  2  RecipeAsSystem             needs admin (asks for elevation)'
    Write-Host '  3  CopyToSystem               needs admin; run 1 in that admin account first'
    Write-Host '  4  SystemPreferredUILanguage  needs admin, Windows 11'
    Write-Host ''
    $choice = Read-Host 'Scenario (1-4)'
    $Scenario = @{ '1' = 'Recipe'; '2' = 'RecipeAsSystem'; '3' = 'CopyToSystem'; '4' = 'SystemPreferredUILanguage' }[$choice.Trim()]
    if (-not $Scenario) { Write-Host 'No scenario selected.' -ForegroundColor Red; Wait-Close; exit 1 }
}

# Scenarios that need admin rights elevate themselves; the elevated window continues the run.
if (-not $isAdmin -and $Scenario -in 'RecipeAsSystem', 'CopyToSystem', 'SystemPreferredUILanguage') {
    Write-Step "$Scenario needs administrator rights - confirm the UAC prompt. The run continues in a new window." 'Yellow'
    $a = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Scenario $Scenario -OutDir `"$OutDir`" -DisplayLanguage $DisplayLanguage -RegionalFormat $RegionalFormat -GeoId $GeoId -Keyboard $($Keyboard -join ',')"
    try { Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $a -Verb RunAs }
    catch { Write-Host "Elevation failed or was cancelled: $($_.Exception.Message)" -ForegroundColor Red }
    Wait-Close
    exit 0
}
if ($Scenario -eq 'Recipe' -and $isAdmin) {
    Write-Host "WARNING: this window is elevated. The Recipe scenario changes the settings of the account running it ($($me.Name))." -ForegroundColor Yellow
    Write-Host 'For the test user, run it from a normal (not elevated) window signed in as that user.' -ForegroundColor Yellow
    if ((Read-Host 'Continue anyway? (y/n)') -notmatch '^[yYjJ]') { Wait-Close; exit 1 }
}

$Keyboard = @($Keyboard | ForEach-Object { ([string]$_).Split(',') } | Where-Object { $_ })
$null = New-Item -ItemType Directory -Path $OutDir -Force
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$transcript = Join-Path $OutDir "${stamp}_${Scenario}_transcript.txt"
try { Start-Transcript -LiteralPath $transcript -Force | Out-Null } catch { }
Write-Step "Scenario $Scenario as $($me.Name). Output folder: $OutDir" 'Green'

$exitCode = 0
try {
# Load the engine from LanguageProfile.ps1 (same worker code as the tool).
$toolPath = Join-Path $PSScriptRoot '..\LanguageProfile.ps1'
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $toolPath), [ref]$tok, [ref]$err)
$assign = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$LPEngineScript' }, $true)
$engineText = $assign.Right.Expression.ScriptBlock.Extent.Text
New-Module -Name LanguageProfileEngine -ScriptBlock ([scriptblock]::Create($engineText.Substring(1, $engineText.Length - 2))) | Import-Module -Force -DisableNameChecking

$noise = @(
    'Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist', 'Software\Microsoft\Windows\CurrentVersion\Explorer\RecentDocs',
    'Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32', 'Software\Microsoft\Windows\CurrentVersion\Explorer\FeatureUsage',
    'Software\Microsoft\Windows\CurrentVersion\Explorer\SessionInfo', 'Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU',
    'Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags', 'Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache',
    'Software\Microsoft\Windows\Shell\BagMRU', 'Software\Microsoft\Windows\Shell\Bags', 'Software\Microsoft\Windows\CurrentVersion\Search\JumplistData',
    'Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags', 'SYSTEM\CurrentControlSet\Control\Session Manager\Power'
)

function Format-RegData($kind, $data) {
    switch ([string]$kind) {
        'Binary' {
            $b = [byte[]]$data
            if ($b.Length -gt 256) { $h = [BitConverter]::ToString((New-Object Security.Cryptography.SHA1Managed).ComputeHash($b)).Replace('-', ''); return "<$($b.Length) bytes sha1 $h>" }
            return [BitConverter]::ToString($b)
        }
        'MultiString' { return '[' + ((@($data) | ForEach-Object { $_ }) -join ' ; ') + ']' }
        'DWord' { return ('0x{0:x8} ({1})' -f [int]$data, $data) }
        'QWord' { return [string]$data }
        default { return [string]$data }
    }
}

function Get-RegDump {
    param($Base, [string]$Path, [string]$Label)
    # Lines: "<Label>\<key relative to Path>\" for keys and "<Label>\<key> | <value> | <kind> | <data>" for values.
    $out = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $p = $stack.Pop()
        if (-not $IncludeNoise) {
            $skip = $false
            foreach ($n in $noise) { if ($p -like "*$n*") { $skip = $true; break } }
            if ($skip) { continue }
        }
        $rel = $p.Substring($Path.Length).TrimStart('\')
        $keyName = $Label
        if ($rel) { $keyName = "$Label\$rel" }
        $k = $null
        try { $k = $Base.OpenSubKey($p, $false) } catch { $out.Add("$keyName | <no access>"); continue }
        if (-not $k) { continue }
        try {
            $out.Add("$keyName\")
            $valueNames = @()
            try { $valueNames = @($k.GetValueNames()) } catch { $out.Add("$keyName | <values not readable: $($_.Exception.Message)>") }
            foreach ($n in $valueNames) {
                $vn = $n; if ($vn -eq '') { $vn = '(Default)' }
                try {
                    $kind = $k.GetValueKind($n)
                    $data = $k.GetValue($n, $null, 'DoNotExpandEnvironmentNames')
                    $out.Add(('{0} | {1} | {2} | {3}' -f $keyName, $vn, $kind, (Format-RegData $kind $data)))
                }
                catch { $out.Add(('{0} | {1} | <error {2}>' -f $keyName, $vn, $_.Exception.Message)) }
            }
            $subNames = @()
            try { $subNames = @($k.GetSubKeyNames()) } catch { $out.Add("$keyName | <subkeys not readable: $($_.Exception.Message)>") }
            foreach ($s in $subNames) { if ($p) { $stack.Push("$p\$s") } else { $stack.Push($s) } }
        }
        finally { $k.Close() }
    }
    return $out
}

function Get-Dump([string[]]$Areas) {
    $hku = [Microsoft.Win32.RegistryKey]::OpenBaseKey('Users', 'Registry64')
    $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Areas) {
        Write-Step "  reading $a ..." 'DarkGray'
        switch ($a) {
            'HKCU' { $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; foreach ($l in (Get-RegDump $hku $sid 'HKCU')) { $lines.Add($l) } }
            'DEFAULT' { foreach ($l in (Get-RegDump $hku '.DEFAULT' 'HKU\.DEFAULT')) { $lines.Add($l) } }
            'S-1-5-19' { foreach ($l in (Get-RegDump $hku 'S-1-5-19' 'HKU\S-1-5-19')) { $lines.Add($l) } }
            'S-1-5-20' { foreach ($l in (Get-RegDump $hku 'S-1-5-20' 'HKU\S-1-5-20')) { $lines.Add($l) } }
            'HKLM' {
                foreach ($p in 'SYSTEM\CurrentControlSet\Control\MUI', 'SYSTEM\CurrentControlSet\Control\Nls', 'SYSTEM\CurrentControlSet\Control\Keyboard Layout',
                    'SYSTEM\CurrentControlSet\Control\CommonGlobUserSettings', 'SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel', 'SOFTWARE\Policies\Microsoft\Control Panel',
                    'SOFTWARE\Microsoft\CTF', 'SOFTWARE\Microsoft\Input') {
                    foreach ($l in (Get-RegDump $hklm $p "HKLM\$p")) { $lines.Add($l) }
                }
            }
            'DefaultHive' {
                $hive = Get-LPDefaultProfileHive
                $r = Invoke-LPReg @('load', 'HKU\LPDIFF_Default', $hive)
                if ($r.ExitCode -ne 0) { $lines.Add("DefaultHive | <could not load $hive : $($r.Output)>"); break }
                try { foreach ($l in (Get-RegDump $hku 'LPDIFF_Default' 'DefaultProfile')) { $lines.Add($l) } }
                finally {
                    [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                    $u = Invoke-LPReg @('unload', 'HKU\LPDIFF_Default')
                    if ($u.ExitCode -ne 0) { Write-Warning "Could not unload HKU\LPDIFF_Default: $($u.Output)" }
                }
            }
        }
    }
    return $lines
}

function Write-Diff([string[]]$BeforeLines, [string[]]$AfterLines, [string]$Title) {
    # Identity of a line = "key | value name" (everything before the second ' | ').
    $b = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $a = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    foreach ($pair in @(@($b, $BeforeLines), @($a, $AfterLines))) {
        $dict = $pair[0]
        foreach ($l in $pair[1]) {
            $id = $l
            $i = $l.IndexOf(' | ')
            if ($i -ge 0) { $j = $l.IndexOf(' | ', $i + 3); if ($j -ge 0) { $id = $l.Substring(0, $j) } }
            $dict[$id] = $l
        }
    }
    $res = New-Object System.Collections.Generic.List[string]
    $keys = New-Object System.Collections.Generic.SortedSet[string]
    $aIds = New-Object 'string[]' $a.Count; $a.Keys.CopyTo($aIds, 0); [Array]::Sort($aIds, [StringComparer]::Ordinal)
    $bIds = New-Object 'string[]' $b.Count; $b.Keys.CopyTo($bIds, 0); [Array]::Sort($bIds, [StringComparer]::Ordinal)
    foreach ($id in $aIds) {
        if (-not $b.ContainsKey($id)) { $res.Add("+ $($a[$id])"); [void]$keys.Add(($id -split ' \| ')[0].TrimEnd('\')) }
        elseif ($b[$id] -ne $a[$id]) { $res.Add("~ $($b[$id])"); $res.Add("  -> $($a[$id])"); [void]$keys.Add(($id -split ' \| ')[0].TrimEnd('\')) }
    }
    foreach ($id in $bIds) {
        if (-not $a.ContainsKey($id)) { $res.Add("- $($b[$id])"); [void]$keys.Add(($id -split ' \| ')[0].TrimEnd('\')) }
    }
    $os = Get-CimInstance Win32_OperatingSystem
    $header = @("# $Title", "# $($os.Caption) build $($os.BuildNumber) - $(Get-Date -Format s) - user $([Security.Principal.WindowsIdentity]::GetCurrent().Name)",
        "# Profile: $DisplayLanguage / $RegionalFormat / GeoId $GeoId / $($Keyboard -join ',')", '# Legend: + added, - removed, ~ changed', '')
    $base = Join-Path $OutDir "${stamp}_$Scenario"
    [IO.File]::WriteAllLines("${base}_diff.txt", [string[]]($header + $res))
    [IO.File]::WriteAllLines("${base}_keys.txt", [string[]]($header + @($keys)))
    [IO.File]::WriteAllLines("${base}_before.txt", [string[]]$BeforeLines)
    [IO.File]::WriteAllLines("${base}_after.txt", [string[]]$AfterLines)
    Write-Step "$($res.Count) difference line(s) in $($keys.Count) key(s)." 'Green'
    $script:written = @("${base}_diff.txt", "${base}_keys.txt")
}

$sel = New-LPSelection -DisplayLanguage $DisplayLanguage -RegionalFormat $RegionalFormat -GeoId $GeoId -Keyboards $Keyboard -TargetIds @()

switch ($Scenario) {
    'Snapshot' {
        $areas = @('HKCU')
        if ($isAdmin) { $areas += 'DEFAULT', 'S-1-5-19', 'S-1-5-20', 'HKLM', 'DefaultHive' }
        $file = Join-Path $OutDir "${stamp}_$Name.txt"
        [IO.File]::WriteAllLines($file, [string[]](Get-Dump $areas))
        Write-Step "Snapshot written: $file" 'Green'
        $script:written = @($file)
    }
    'Compare' {
        if (-not $Before -or -not $After) { throw 'Use -Before <file> -After <file>.' }
        Write-Diff ([IO.File]::ReadAllLines($Before)) ([IO.File]::ReadAllLines($After)) "Compare $Before -> $After"
    }
    'Recipe' {
        $areas = @('HKCU', 'DEFAULT')
        Write-Step 'Reading the registry BEFORE (can take 1-3 minutes, please wait)...'
        $dumpBefore = Get-Dump $areas
        Write-Step "  $($dumpBefore.Count) lines" 'DarkGray'
        $job = Join-Path ([IO.Path]::GetTempPath()) "lpdiff-$stamp"
        $null = New-Item -ItemType Directory -Path (Join-Path $job 'out') -Force
        $j = [ordered]@{ ExpectedSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; DisplayLanguage = $sel.DisplayLanguage; DisplayLcid = [int]$sel.DisplayLcid; RegionalFormat = $sel.RegionalFormat; GeoId = $sel.GeoId; Tips = @($sel.Tips); DisableSync = $true }
        [IO.File]::WriteAllText((Join-Path $job 'job.json'), ($j | ConvertTo-Json))
        Write-Step "Running the recipe in this account ($($me.Name), $($j.ExpectedSid))..."
        & ([scriptblock]::Create((Get-LPWorkerScriptText))) -JobDir $job
        Get-Content (Join-Path $job 'out\worker.log') | ForEach-Object { Write-Host "  $_" }
        $wr = [IO.File]::ReadAllText((Join-Path $job 'out\result.json')) | ConvertFrom-Json
        if ($wr.Success) { Write-Step 'Recipe: success' 'Green' } else { Write-Step "Recipe FAILED: $($wr.Error)" 'Red' }
        Start-Sleep -Seconds 3
        Write-Step 'Reading the registry AFTER (can take 1-3 minutes)...'
        $dumpAfter = Get-Dump $areas
        Write-Diff $dumpBefore $dumpAfter 'Recipe in the current user (worker code of LanguageProfile.ps1)'
    }
    'RecipeAsSystem' {
        if (-not $isAdmin) { throw 'Run elevated.' }
        $null = Initialize-LPEngine -ScriptRoot (Split-Path $toolPath) -Console -LogName 'RegistryDiff'
        $areas = @('DEFAULT', 'S-1-5-19', 'S-1-5-20', 'HKLM')
        Write-Step 'Reading the registry BEFORE...'
        $dumpBefore = Get-Dump $areas
        Write-Step 'Running the recipe as SYSTEM through a one-time scheduled task...'
        $w = Invoke-LPWorkerTask -Sid 'S-1-5-18' -Label 'SYSTEM (diff)' -Selection $sel
        if ($w.Success) { Write-Step 'Worker as SYSTEM: success' 'Green' } else { Write-Step "Worker as SYSTEM FAILED: $($w.Error)" 'Red' }
        Start-Sleep -Seconds 3
        Write-Step 'Reading the registry AFTER...'
        $dumpAfter = Get-Dump $areas
        Write-Diff $dumpBefore $dumpAfter 'Recipe as SYSTEM via scheduled task (writes HKU\.DEFAULT)'
    }
    'CopyToSystem' {
        if (-not $isAdmin) { throw 'Run elevated.' }
        $areas = @('DEFAULT', 'S-1-5-19', 'S-1-5-20', 'HKLM', 'DefaultHive')
        Write-Step 'Reading the registry BEFORE...'
        $dumpBefore = Get-Dump $areas
        $build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
        if (Get-Command Copy-UserInternationalSettingsToSystem -ErrorAction SilentlyContinue) {
            Write-Host 'Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true'
            Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
        }
        else {
            $xml = Join-Path ([IO.Path]::GetTempPath()) "lpdiff-$stamp.xml"
            @'
<gs:GlobalizationServices xmlns:gs="urn:longhornGlobalizationUnattend">
  <gs:UserList>
    <gs:User UserID="Current" CopySettingsToDefaultUserAcct="true" CopySettingsToSystemAcct="true"/>
  </gs:UserList>
</gs:GlobalizationServices>
'@ | Set-Content -LiteralPath $xml -Encoding UTF8
            Write-Host "control.exe intl.cpl,,/f:`"$xml`" (build $build)"
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\control.exe') -ArgumentList "intl.cpl,,/f:`"$xml`"" -Wait
            for ($i = 0; $i -lt 60; $i++) {
                $busy = @(Get-CimInstance Win32_Process -Filter "Name='rundll32.exe'" | Where-Object { $_.CommandLine -match 'intl\.cpl' })
                if ($busy.Count -eq 0) { break }
                Start-Sleep -Seconds 1
            }
        }
        Start-Sleep -Seconds 5
        Write-Step 'Reading the registry AFTER...'
        $dumpAfter = Get-Dump $areas
        Write-Diff $dumpBefore $dumpAfter 'Microsoft copy to welcome screen / system accounts / new users'
    }
    'SystemPreferredUILanguage' {
        if (-not $isAdmin) { throw 'Run elevated.' }
        if (-not (Get-Command Set-SystemPreferredUILanguage -ErrorAction SilentlyContinue)) { throw 'Set-SystemPreferredUILanguage is not available on this Windows.' }
        $areas = @('DEFAULT', 'HKLM')
        Write-Step 'Reading the registry BEFORE...'
        $dumpBefore = Get-Dump $areas
        Write-Step "Set-SystemPreferredUILanguage $DisplayLanguage"
        Set-SystemPreferredUILanguage -Language $DisplayLanguage
        Start-Sleep -Seconds 3
        Write-Step 'Reading the registry AFTER...'
        $dumpAfter = Get-Dump $areas
        Write-Diff $dumpBefore $dumpAfter "Set-SystemPreferredUILanguage $DisplayLanguage"
    }
}
}
catch {
    $exitCode = 1
    Write-Host ''
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
}
finally {
    Write-Host ''
    if ($script:written) {
        Write-Step 'Done. Please send these files back:' 'Green'
        foreach ($f in $script:written) { Write-Host "  $f" -ForegroundColor Green }
        Write-Host "  $transcript" -ForegroundColor Green
    }
    else { Write-Step "No diff was written. Please send the transcript: $transcript" 'Yellow' }
    try { Stop-Transcript | Out-Null } catch { }
}
Wait-Close
exit $exitCode
