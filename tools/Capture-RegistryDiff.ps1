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

    Output (default .\diff-output): *_diff.txt (added/removed/changed values) and *_keys.txt (keys touched).
    Please send both files back - they define the registry key list in README.md and $script:LanguageKeySet.

.EXAMPLE
    # as the test user
    powershell -ExecutionPolicy Bypass -File .\tools\Capture-RegistryDiff.ps1 -Scenario Recipe
.EXAMPLE
    # elevated
    powershell -ExecutionPolicy Bypass -File .\tools\Capture-RegistryDiff.ps1 -Scenario RecipeAsSystem
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Recipe', 'RecipeAsSystem', 'CopyToSystem', 'SystemPreferredUILanguage', 'Snapshot', 'Compare')][string]$Scenario,
    [string]$DisplayLanguage = 'en-US',
    [string]$RegionalFormat = 'de-CH',
    [int]$GeoId = 223,
    [string[]]$Keyboard = @('00000807'),
    [string]$OutDir = (Join-Path (Get-Location) 'diff-output'),
    [string]$Name = 'snapshot',
    [string]$Before,
    [string]$After,
    [switch]$IncludeNoise
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Run this in Windows PowerShell 5.1 (powershell.exe).' }
$null = New-Item -ItemType Directory -Path $OutDir -Force
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

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
        'DWord' { return ('0x{0:x8} ({1})' -f ([uint32]([int64]$data -band 0xffffffff)), $data) }
        default { return [string]$data }
    }
}

function Get-RegDump {
    param($Base, [string]$Path, [string]$Label)
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
        $k = $null
        try { $k = $Base.OpenSubKey($p, $false) } catch { $out.Add("$Label\$p | <no access>"); continue }
        if (-not $k) { continue }
        try {
            $out.Add("$Label\$p\")
            foreach ($n in $k.GetValueNames()) {
                $kind = $k.GetValueKind($n)
                $data = $k.GetValue($n, $null, 'DoNotExpandEnvironmentNames')
                $vn = $n; if ($vn -eq '') { $vn = '(Default)' }
                $out.Add(('{0}\{1} | {2} | {3} | {4}' -f $Label, $p, $vn, $kind, (Format-RegData $kind $data)))
            }
            foreach ($s in $k.GetSubKeyNames()) { if ($p) { $stack.Push("$p\$s") } else { $stack.Push($s) } }
        }
        catch { $out.Add("$Label\$p | <error $($_.Exception.Message)>") }
        finally { $k.Close() }
    }
    return $out
}

function Get-Dump([string[]]$Areas) {
    $hku = [Microsoft.Win32.RegistryKey]::OpenBaseKey('Users', 'Registry64')
    $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Areas) {
        switch ($a) {
            'HKCU' { $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; foreach ($l in (Get-RegDump $hku $sid 'HKCU')) { $lines.Add($l) } }
            'DEFAULT' { foreach ($l in (Get-RegDump $hku '.DEFAULT' 'HKU\.DEFAULT')) { $lines.Add($l) } }
            'S-1-5-19' { foreach ($l in (Get-RegDump $hku 'S-1-5-19' 'HKU\S-1-5-19')) { $lines.Add($l) } }
            'S-1-5-20' { foreach ($l in (Get-RegDump $hku 'S-1-5-20' 'HKU\S-1-5-20')) { $lines.Add($l) } }
            'HKLM' {
                foreach ($p in 'SYSTEM\CurrentControlSet\Control\MUI', 'SYSTEM\CurrentControlSet\Control\Nls', 'SYSTEM\CurrentControlSet\Control\Keyboard Layout',
                    'SYSTEM\CurrentControlSet\Control\CommonGlobUserSettings', 'SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel', 'SOFTWARE\Policies\Microsoft\Control Panel',
                    'SOFTWARE\Microsoft\CTF', 'SOFTWARE\Microsoft\Input') {
                    foreach ($l in (Get-RegDump $hklm $p 'HKLM')) { $lines.Add($l) }
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
    $parse = {
        param($l)
        $parts = $l -split ' \| ', 2
        [pscustomobject]@{ Id = $parts[0] + $(if ($parts.Count -gt 1) { ' | ' + ($parts[1] -split ' \| ')[0] } else { '' }); Line = $l }
    }
    $b = @{}; foreach ($l in $BeforeLines) { $x = & $parse $l; $b[$x.Id] = $l }
    $a = @{}; foreach ($l in $AfterLines) { $x = & $parse $l; $a[$x.Id] = $l }
    $res = New-Object System.Collections.Generic.List[string]
    $keys = New-Object System.Collections.Generic.SortedSet[string]
    foreach ($id in ($a.Keys | Sort-Object)) {
        if (-not $b.ContainsKey($id)) { $res.Add("+ $($a[$id])"); [void]$keys.Add(($id -split ' \| ')[0].TrimEnd('\')) }
        elseif ($b[$id] -ne $a[$id]) { $res.Add("~ $($b[$id])"); $res.Add("  -> $($a[$id])"); [void]$keys.Add(($id -split ' \| ')[0].TrimEnd('\')) }
    }
    foreach ($id in ($b.Keys | Sort-Object)) {
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
    Write-Host "$($res.Count) difference line(s) in $($keys.Count) key(s)."
    Write-Host "Send back: ${base}_diff.txt and ${base}_keys.txt" -ForegroundColor Green
}

$sel = New-LPSelection -DisplayLanguage $DisplayLanguage -RegionalFormat $RegionalFormat -GeoId $GeoId -Keyboards $Keyboard -TargetIds @()

switch ($Scenario) {
    'Snapshot' {
        $areas = @('HKCU')
        if ($isAdmin) { $areas += 'DEFAULT', 'S-1-5-19', 'S-1-5-20', 'HKLM', 'DefaultHive' }
        $file = Join-Path $OutDir "${stamp}_$Name.txt"
        [IO.File]::WriteAllLines($file, [string[]](Get-Dump $areas))
        Write-Host "Snapshot written: $file"
    }
    'Compare' {
        if (-not $Before -or -not $After) { throw 'Use -Before <file> -After <file>.' }
        Write-Diff ([IO.File]::ReadAllLines($Before)) ([IO.File]::ReadAllLines($After)) "Compare $Before -> $After"
    }
    'Recipe' {
        $areas = @('HKCU', 'DEFAULT')
        $before = Get-Dump $areas
        $job = Join-Path ([IO.Path]::GetTempPath()) "lpdiff-$stamp"
        $null = New-Item -ItemType Directory -Path (Join-Path $job 'out') -Force
        $j = [ordered]@{ ExpectedSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; DisplayLanguage = $sel.DisplayLanguage; RegionalFormat = $sel.RegionalFormat; GeoId = $sel.GeoId; Tips = @($sel.Tips); DisableSync = $true }
        [IO.File]::WriteAllText((Join-Path $job 'job.json'), ($j | ConvertTo-Json))
        Write-Host "Running the recipe in this account ($($j.ExpectedSid))..."
        & ([scriptblock]::Create((Get-LPWorkerScriptText))) -JobDir $job
        Get-Content (Join-Path $job 'out\worker.log') | ForEach-Object { Write-Host "  $_" }
        Start-Sleep -Seconds 3
        $after = Get-Dump $areas
        Write-Diff $before $after 'Recipe in the current user (worker code of LanguageProfile.ps1)'
    }
    'RecipeAsSystem' {
        if (-not $isAdmin) { throw 'Run elevated.' }
        $null = Initialize-LPEngine -ScriptRoot (Split-Path $toolPath) -Console -LogName 'RegistryDiff'
        $areas = @('DEFAULT', 'S-1-5-19', 'S-1-5-20', 'HKLM')
        $before = Get-Dump $areas
        $w = Invoke-LPWorkerTask -Sid 'S-1-5-18' -Label 'SYSTEM (diff)' -Selection $sel
        Write-Host ("Worker success: {0} {1}" -f $w.Success, $w.Error)
        Start-Sleep -Seconds 3
        $after = Get-Dump $areas
        Write-Diff $before $after 'Recipe as SYSTEM via scheduled task (writes HKU\.DEFAULT)'
    }
    'CopyToSystem' {
        if (-not $isAdmin) { throw 'Run elevated.' }
        $areas = @('DEFAULT', 'S-1-5-19', 'S-1-5-20', 'HKLM', 'DefaultHive')
        $before = Get-Dump $areas
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
        $after = Get-Dump $areas
        Write-Diff $before $after 'Microsoft copy to welcome screen / system accounts / new users'
    }
    'SystemPreferredUILanguage' {
        if (-not $isAdmin) { throw 'Run elevated.' }
        if (-not (Get-Command Set-SystemPreferredUILanguage -ErrorAction SilentlyContinue)) { throw 'Set-SystemPreferredUILanguage is not available on this Windows.' }
        $areas = @('DEFAULT', 'HKLM')
        $before = Get-Dump $areas
        Set-SystemPreferredUILanguage -Language $DisplayLanguage
        Start-Sleep -Seconds 3
        $after = Get-Dump $areas
        Write-Diff $before $after "Set-SystemPreferredUILanguage $DisplayLanguage"
    }
}
