<#
.SYNOPSIS
    Unit tests for the pure parts of the Language Profile engine (no registry, no changes).
    Runs in PowerShell 7 on any OS (CI/Linux) and in Windows PowerShell 5.1:
        pwsh -File tests/Engine.Tests.ps1
    The engine script block is extracted from LanguageProfile.ps1 via the AST, so the script's
    PowerShell 5.1 guard and the UI are not executed.
#>
param([string]$Path = (Join-Path $PSScriptRoot '..\LanguageProfile.ps1'))
$ErrorActionPreference = 'Stop'

# Minimal in-memory registry with the RegistryKey methods the engine uses (case-insensitive like the real one).
class FakeNode {
    [hashtable]$Values = @{}
    [hashtable]$Kinds = @{}
    [hashtable]$Subs = @{}
}
class FakeKey {
    [FakeNode]$Node
    FakeKey([FakeNode]$n) { $this.Node = $n }
    hidden [FakeNode] Walk([string]$path, [bool]$create) {
        $n = $this.Node
        foreach ($part in $path.Split('\')) {
            if ($part -eq '') { continue }
            if (-not $n.Subs.ContainsKey($part)) {
                if (-not $create) { return $null }
                $n.Subs[$part] = [FakeNode]::new()
            }
            $n = $n.Subs[$part]
        }
        return $n
    }
    [object] OpenSubKey([string]$p) { return $this.OpenSubKey($p, $false) }
    [object] OpenSubKey([string]$p, [bool]$w) { $n = $this.Walk($p, $false); if ($null -eq $n) { return $null }; return [FakeKey]::new($n) }
    [object] CreateSubKey([string]$p) { return [FakeKey]::new($this.Walk($p, $true)) }
    [string[]] GetValueNames() { return [string[]]@($this.Node.Values.Keys) }
    [string[]] GetSubKeyNames() { return [string[]]@($this.Node.Subs.Keys) }
    [object] GetValue([string]$n) { return $this.GetValue($n, $null) }
    [object] GetValue([string]$n, [object]$d) { if ($this.Node.Values.ContainsKey($n)) { return $this.Node.Values[$n] }; return $d }
    [object] GetValue([string]$n, [object]$d, [object]$o) { return $this.GetValue($n, $d) }
    [object] GetValueKind([string]$n) { return [Microsoft.Win32.RegistryValueKind]$this.Node.Kinds[$n] }
    [void] SetValue([string]$n, [object]$v, [object]$k) { $this.Node.Values[$n] = $v; $this.Node.Kinds[$n] = [string]$k }
    [void] DeleteValue([string]$n, [bool]$t) { $this.Node.Values.Remove($n); $this.Node.Kinds.Remove($n) }
    [void] DeleteSubKeyTree([string]$p, [bool]$t) {
        $parts = @($p.Split('\') | Where-Object { $_ })
        $n = $this.Node
        for ($i = 0; $i -lt $parts.Count - 1; $i++) { if (-not $n.Subs.ContainsKey($parts[$i])) { return }; $n = $n.Subs[$parts[$i]] }
        $n.Subs.Remove($parts[$parts.Count - 1])
    }
    [void] Close() { }
}

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Path), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Parse errors in $Path" }
$assign = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$LPEngineScript' }, $true)
$engineText = $assign.Right.Expression.ScriptBlock.Extent.Text
$engineText = $engineText.Substring(1, $engineText.Length - 2)
New-Module -Name LanguageProfileEngine -ScriptBlock ([scriptblock]::Create($engineText)) | Import-Module -Force -DisableNameChecking

$script:pass = 0; $script:fail = 0
function Assert([bool]$Condition, [string]$Name) {
    if ($Condition) { $script:pass++; Write-Host "  ok   $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
}
function Eq($a, $b) { return ((@($a) -join '|') -eq (@($b) -join '|')) }

# ------------------------------------------------------------------------------------------------
Write-Host 'Tips and selection'
Assert ((ConvertTo-LPTip -Lcid 0x409 -LayoutId '00000807') -eq '0409:00000807') 'tip format LLLL:KKKKKKKK'
$sel = New-LPSelection -DisplayLanguage 'en-us' -RegionalFormat 'de-ch' -Keyboards @('00000807', 'bad', '00000807') -TargetIds @('lockscreen', 'newusers')
Assert ($sel.DisplayLanguage -eq 'en-US') 'display language canonicalized'
Assert ($sel.RegionalFormat -eq 'de-CH') 'format canonicalized'
Assert (Eq $sel.Keyboards @('00000807')) 'keyboards deduplicated'
Assert (Eq $sel.InvalidKeyboards @('bad')) 'invalid keyboard reported'
Assert (Eq $sel.Tips @('0409:00000807')) 'tips built from display LCID'
Assert ($sel.GeoId -eq 223) 'GeoId defaults to the format''s region (223 = Switzerland)'
Assert ($sel.SystemLocale -eq 'de-CH') 'system locale defaults to the format'

# ------------------------------------------------------------------------------------------------
Write-Host 'Preload rewrite'
$p = Get-LPPreloadPlan -DesiredTips @('0409:00000807') -Preload @('00000409') -Substitutes @{}
Assert (Eq $p.Preload @('d0010409')) 'US keyboard replaced by substitute entry for Swiss German on en-US'
Assert ($p.Substitutes['d0010409'] -eq '00000807') 'substitute d0010409 -> 00000807'
Assert (Eq ($p.Removed | ForEach-Object Tip) @('0409:00000409')) 'US keyboard reported as removed'

$p = Get-LPPreloadPlan -DesiredTips @('0409:00000807') -Preload @('d0010409', '00000807', '00000409', 'garbage') -Substitutes @{ 'd0010409' = '00000807'; 'd0020407' = '00000409' }
Assert (Eq $p.Preload @('d0010409')) 'existing substitute kept, others removed'
Assert (@($p.Substitutes.Keys).Count -eq 1) 'unreferenced substitutes dropped'
Assert (@($p.Removed).Count -eq 3) 'hidden 0807:00000807, 0409:00000409 and garbage removed'

$p = Get-LPPreloadPlan -DesiredTips @('0409:00000807', '0409:00000409') -Preload @('00000409', 'd0010409') -Substitutes @{ 'D0010409' = '00000807' }
Assert (Eq $p.Preload @('d0010409', '00000409')) 'reordered to desired order (first = default), case-insensitive substitutes'

$p = Get-LPPreloadPlan -DesiredTips @('0409:00000807') -Preload @('d0010409', 'd0020409') -Substitutes @{ 'd0010409' = '00000409'; 'd0020409' = '00000807' }
Assert (Eq $p.Preload @('d0020409')) 'picks the substitute that maps to the desired layout'

$p = Get-LPPreloadPlan -DesiredTips @('0409:00000807', '0409:0000100C') -Preload @() -Substitutes @{ 'd0010409' = '00000409' }
Assert (Eq $p.Preload @('d0020409', 'd0030409')) 'new substitute names avoid existing ones'
Assert (Eq $p.Added @('0409:00000807', '0409:0000100C')) 'added tips reported'

$p = Get-LPPreloadPlan -DesiredTips @('0807:00000807') -Preload @('00000807', '00000807') -Substitutes @{}
Assert (Eq $p.Preload @('00000807')) 'duplicate entries collapse'

# ------------------------------------------------------------------------------------------------
Write-Host 'Readiness and plan'
function New-FakeState([string[]]$Langs, [hashtable]$Tips, [string]$Ui, [string]$Fmt, [int]$Geo, [string[]]$PreloadTips, $Sync = $null, [string[]]$Hidden = @()) {
    $lt = [ordered]@{}
    foreach ($l in $Langs) { $lt[$l] = @($Tips[$l]) }
    $all = @(); foreach ($l in $Langs) { $all += @($Tips[$l]) }
    [pscustomobject]@{ Languages = $Langs; LanguageTips = $lt; Tips = $all; InputMethodOverride = $all[0]; UILanguage = $Ui; UILanguagePending = $null; MachineUILanguage = $Ui
        Format = $Fmt; GeoId = $Geo; Preload = @(); PreloadTips = $PreloadTips; Substitutes = @{}; Hidden = $Hidden; SyncEnabled = $Sync }
}
function New-FakeSnapshot([string[]]$Installed = @('en-US'), [string[]]$Full = @('en-US'), [bool]$InstallLanguage = $true, [bool]$Win11 = $true, [bool]$PendingReboot = $false, $Policies = @(), $Wsus = $null, [string]$SysUi = 'en-US') {
    $gerState = New-FakeState -Langs @('de-CH', 'en-US') -Tips @{ 'de-CH' = @('0807:00000807'); 'en-US' = @('0409:00000409') } -Ui 'de-DE' -Fmt 'de-CH' -Geo 223 -PreloadTips @('0807:00000807', '0409:00000409') -Hidden @('0407:00000407')
    $profiles = @(
        [pscustomobject]@{ Id = 'user:S-1-5-21-1-2-3-1001'; Kind = 'User'; Sid = 'S-1-5-21-1-2-3-1001'; Name = 'PC\alice'; ProfilePath = 'C:\Users\alice'; HivePath = 'C:\Users\alice\NTUSER.DAT'; HiveExists = $true; SignedIn = $true; SessionIds = @(1); HiveLoaded = $true; IsProcessUser = $false; Method = 'Task'; State = $gerState; StateError = $null; Policies = @() }
        [pscustomobject]@{ Id = 'user:S-1-5-21-1-2-3-1002'; Kind = 'User'; Sid = 'S-1-5-21-1-2-3-1002'; Name = 'PC\bob'; ProfilePath = 'C:\Users\bob'; HivePath = 'C:\Users\bob\NTUSER.DAT'; HiveExists = $true; SignedIn = $false; SessionIds = @(); HiveLoaded = $false; IsProcessUser = $false; Method = 'Offline'; State = $gerState; StateError = $null; Policies = @() }
        [pscustomobject]@{ Id = 'user:S-1-5-21-1-2-3-500'; Kind = 'User'; Sid = 'S-1-5-21-1-2-3-500'; Name = 'PC\admin'; ProfilePath = 'C:\Users\admin'; HivePath = 'C:\Users\admin\NTUSER.DAT'; HiveExists = $true; SignedIn = $false; SessionIds = @(); HiveLoaded = $true; IsProcessUser = $true; Method = 'Loaded'; State = $gerState; StateError = $null; Policies = @() }
    )
    $w = $Wsus
    if (-not $w) { $w = [pscustomobject]@{ UseWUServer = $null; WUServer = $null; RepairContentServerSource = $null; LocalSourcePath = $null; UseWindowsUpdate = $null } }
    [pscustomobject]@{
        ScanTime     = Get-Date
        Os           = [pscustomobject]@{ Name = 'Windows test'; Build = $(if ($Win11) { 26100 } else { 19045 }); IsWin11 = $Win11; SingleLanguage = $false; EditionId = 'Professional'; MUILanguages = $Full }
        Process      = [pscustomobject]@{ UserName = 'PC\admin'; Sid = 'S-1-5-21-1-2-3-500'; IsSystem = $false; IsAdmin = $true; LanguageMode = 'FullLanguage' }
        Capabilities = [pscustomobject]@{ InstallLanguage = $InstallLanguage; InstallLanguageExcludeFeatures = $true; GetInstalledLanguage = $true; UninstallLanguage = $true; SetSystemPreferredUILanguage = $true; GetSystemPreferredUILanguage = $true; CopyUserInternationalSettingsToSystem = $Win11; AddWindowsPackage = $true; TaskScheduler = $true }
        Languages    = [pscustomobject]@{ Installed = $Installed; FullPack = $Full; LxpOnly = @($Installed | Where-Object { $Full -notcontains $_ }); Details = @(); SystemPreferredUILanguage = $SysUi; SystemLocale = 'de-CH'; InstallLanguage = $SysUi }
        Machine      = [pscustomobject]@{ IgnoreRemoteKeyboardLayout = $null; Policies = $Policies; Wsus = $w; PendingReboot = [pscustomobject]@{ Pending = $PendingReboot; Reasons = @(if ($PendingReboot) { 'test' }) }; ExecutionPolicy = 'Undefined' }
        Profiles     = $profiles
        LockScreen   = [pscustomobject]@{ Id = 'lockscreen'; Kind = 'LockScreen'; Name = 'Lock screen'; State = $gerState; StateError = $null; Policies = @() }
        NewUsers     = [pscustomobject]@{ Id = 'newusers'; Kind = 'NewUsers'; Name = 'New users'; HivePath = 'C:\Users\Default\NTUSER.DAT'; State = $gerState; StateError = $null; Policies = @() }
        KeyboardLayouts = @([pscustomobject]@{ Id = '00000807'; Name = 'Swiss German'; File = 'KBDSG.DLL'; FileExists = $true; Display = 'Swiss German (00000807)' }, [pscustomobject]@{ Id = '00000409'; Name = 'US'; File = 'KBDUS.DLL'; FileExists = $true; Display = 'US (00000409)' })
        Errors       = @()
    }
}
$std = New-LPSelection -DisplayLanguage 'en-US' -RegionalFormat 'de-CH' -GeoId 223 -Keyboards @('00000807') -TargetIds @('user:S-1-5-21-1-2-3-1001', 'lockscreen', 'newusers')

# English Windows: everything present
$snap = New-FakeSnapshot
Assert (Eq (Get-LPDefaultTargetIds $snap) @('user:S-1-5-21-1-2-3-1001', 'lockscreen', 'newusers')) 'default targets = signed-in user + lock screen + new users'
$r = Test-LPReadiness -Snapshot $snap -Selection $std
Assert ($r.CanApply) 'standard preset ready on English Windows'
Assert (-not $r.PackNeeded) 'no pack needed'
Assert (@($r.Items | Where-Object { $_.State -eq 'Blocked' }).Count -eq 0) 'nothing blocked'
$plan = New-LPPlan -Snapshot $snap -Selection $std -Readiness $r
$kinds = @($plan.Steps | ForEach-Object Kind)
Assert (Eq $kinds @('SystemUILanguage', 'RemoteKeyboard', 'Reference', 'SystemAccounts', 'NewUsers', 'User')) "step order: $($kinds -join ',')"
Assert (@($plan.Lines | Where-Object { $_.Level -eq 'Remove' -and $_.Text -like '*de-CH*' }).Count -gt 0) 'preview shows de-CH language being removed'
Assert (@($plan.Lines | Where-Object { $_.Level -eq 'Remove' -and $_.Text -like 'Hidden layout*' }).Count -gt 0) 'preview shows hidden layout being removed'
Assert ((Get-LPPlanSummaryText -Plan $plan -Snapshot $snap) -like '*PC\alice*') 'summary names the target user'

# German Windows, en-US missing, Install-Language available
$snap = New-FakeSnapshot -Installed @('de-DE') -Full @('de-DE') -SysUi 'de-DE'
$r = Test-LPReadiness -Snapshot $snap -Selection $std
Assert ($r.CanApply -and $r.PackNeeded -and $r.PackMethod -eq 'InstallLanguage') 'German Windows: en-US will be installed automatically'
Assert (@($r.Items | Where-Object { $_.Id -eq 'pack' -and $_.State -eq 'Auto' }).Count -eq 1) 'pack item state = Auto'
$plan = New-LPPlan -Snapshot $snap -Selection $std -Readiness $r
Assert ($plan.Steps[0].Kind -eq 'InstallPack') 'install is the first step'
Assert ((@($plan.Lines | ForEach-Object Text) -join ' ') -match 'Install-Language') 'preview mentions Install-Language'

# German Windows, no Install-Language: blocked, cascade, partial possible
$snap = New-FakeSnapshot -Installed @('de-DE') -Full @('de-DE') -InstallLanguage $false -SysUi 'de-DE'
$r = Test-LPReadiness -Snapshot $snap -Selection $std
Assert (-not $r.CanApply) 'blocked when the pack cannot be installed'
Assert (@($r.BlockedParts) -contains 'lockscreen' -and @($r.BlockedParts) -contains 'user:S-1-5-21-1-2-3-1001') 'missing pack blocks account settings (cascade)'
Assert (Eq $r.ReadyParts @('machine')) 'only the machine option is ready'
Assert ($r.CanApplyReadyParts) 'partial apply offered'
$packItem = @($r.Items | Where-Object { $_.Id -eq 'pack' })[0]
Assert ((@($packItem.Steps) -join ' ') -match 'Settings > Time & language' -and (@($packItem.Steps) -join ' ') -match 'DISM /Online /Add-Package') 'manual steps for user and IT'
$plan = New-LPPlan -Snapshot $snap -Selection $std -Readiness $r
Assert (-not $plan.Executable) 'no plan without explicit partial apply'
$plan = New-LPPlan -Snapshot $snap -Selection $std -Readiness $r -ReadyPartsOnly
Assert ((Eq (@($plan.Steps | ForEach-Object Kind)) @('RemoteKeyboard')) -and $plan.ReadyPartsOnly) 'partial plan contains only ready parts'
Assert (@($plan.Lines | Where-Object { $_.Text -like 'PARTIAL*' }).Count -eq 1) 'partial plan says so'

# WSUS hint
$wsus = [pscustomobject]@{ UseWUServer = 1; WUServer = 'http://wsus:8530'; RepairContentServerSource = $null; LocalSourcePath = $null; UseWindowsUpdate = $null }
$snap = New-FakeSnapshot -Installed @('de-DE') -Full @('de-DE') -Wsus $wsus -SysUi 'de-DE'
$r = Test-LPReadiness -Snapshot $snap -Selection $std
Assert (@($r.Items | Where-Object { $_.Id -eq 'wsus' -and $_.State -eq 'Warn' }).Count -eq 1) 'WSUS without repair source -> 0x800f0954 warning'

# Pending reboot + pack needed
$snap = New-FakeSnapshot -Installed @('de-DE') -Full @('de-DE') -PendingReboot $true -SysUi 'de-DE'
$r = Test-LPReadiness -Snapshot $snap -Selection $std
Assert (@($r.Items | Where-Object { $_.Id -eq 'reboot' -and $_.State -eq 'Blocked' }).Count -eq 1) 'pending restart blocks a pack install'
$snap = New-FakeSnapshot -PendingReboot $true
$r = Test-LPReadiness -Snapshot $snap -Selection $std
Assert ($r.CanApply -and @($r.Items | Where-Object { $_.Id -eq 'reboot' -and $_.State -eq 'Warn' }).Count -eq 1) 'pending restart only warns when nothing is installed'

# Unknown keyboard
$bad = New-LPSelection -DisplayLanguage 'en-US' -RegionalFormat 'de-CH' -Keyboards @('A0000807') -TargetIds @('lockscreen')
$r = Test-LPReadiness -Snapshot (New-FakeSnapshot) -Selection $bad
Assert (@($r.Items | Where-Object { $_.Id -eq 'kb:A0000807' -and $_.State -eq 'Blocked' }).Count -eq 1) 'custom layout that is not installed is blocked'

# Neutral format
$bad = New-LPSelection -DisplayLanguage 'en-US' -RegionalFormat 'de' -GeoId 223 -Keyboards @('00000807') -TargetIds @('lockscreen')
$r = Test-LPReadiness -Snapshot (New-FakeSnapshot) -Selection $bad
Assert (@($r.Items | Where-Object { $_.Id -eq 'format' -and $_.State -eq 'Blocked' }).Count -eq 1) 'neutral culture is blocked'

# Policy forcing another display language
$pol = @([pscustomobject]@{ Scope = 'Machine'; Label = 'This PC'; Key = 'HKLM\SOFTWARE\Policies\Microsoft\MUI\Settings'; Name = 'PreferredUILanguages'; Value = 'de-DE'; Source = 'Group Policy / Intune' })
$r = Test-LPReadiness -Snapshot (New-FakeSnapshot -Policies $pol) -Selection $std
$pi = @($r.Items | Where-Object { $_.Id -like 'policy:*' })[0]
Assert ($pi.State -eq 'Blocked' -and (@($pi.Detail) -join ' ') -match 'gpresult') 'UI language policy blocks and explains who changes what'
Assert (Eq (@($r.ReadyParts)) @('machine')) 'policy blocks all account settings, machine option stays ready'
$pol = @([pscustomobject]@{ Scope = 'Machine'; Label = 'This PC'; Key = 'HKLM\...'; Name = 'PreferredUILanguages'; Value = 'en-US'; Source = 'GPO' })
$r = Test-LPReadiness -Snapshot (New-FakeSnapshot -Policies $pol) -Selection $std
Assert ($r.CanApply) 'policy that forces the same language is only info'

# LXP-only display language and the lock screen
$snap = New-FakeSnapshot -Installed @('de-DE', 'en-US') -Full @('de-DE') -Win11 $false -InstallLanguage $false -SysUi 'de-DE'
$r = Test-LPReadiness -Snapshot $snap -Selection $std
Assert (Eq (@($r.BlockedParts)) @('lockscreen')) 'Windows 10 + LXP-only, no Install-Language: only the lock screen is blocked'
$snap = New-FakeSnapshot -Installed @('de-DE', 'en-US') -Full @('de-DE') -Win11 $false -SysUi 'de-DE'
$r = Test-LPReadiness -Snapshot $snap -Selection $std
Assert ($r.CanApply -and $r.PackNeeded -and $r.PackMethod -eq 'InstallLanguage') 'Windows 10 + LXP-only + Install-Language: full pack added automatically'
$snap = New-FakeSnapshot -Installed @('de-DE', 'en-US') -Full @('de-DE') -Win11 $false -SysUi 'de-DE' -PendingReboot $true
$r = Test-LPReadiness -Snapshot $snap -Selection $std
Assert ((Eq (@($r.ReadyParts | Sort-Object)) @('machine', 'newusers', 'user:S-1-5-21-1-2-3-1001')) -and -not (@($r.ReadyParts) -contains 'lockscreen')) 'blocked full-pack upgrade only blocks the lock screen'
$snap = New-FakeSnapshot -Installed @('de-DE', 'en-US') -Full @('de-DE') -Win11 $true -SysUi 'de-DE'
$r = Test-LPReadiness -Snapshot $snap -Selection $std
Assert ($r.CanApply -and @($r.Items | Where-Object { $_.Id -eq 'lockpack' -and $_.State -eq 'Warn' }).Count -eq 1) 'Windows 11 + LXP-only: warning only'

# Lock screen not selected but an offline user is: reference is restored
$sel2 = New-LPSelection -DisplayLanguage 'en-US' -RegionalFormat 'de-CH' -Keyboards @('00000807') -TargetIds @('user:S-1-5-21-1-2-3-1002')
$snap = New-FakeSnapshot
$r = Test-LPReadiness -Snapshot $snap -Selection $sel2
$plan = New-LPPlan -Snapshot $snap -Selection $sel2 -Readiness $r
Assert (Eq (@($plan.Steps | ForEach-Object Kind)) @('RemoteKeyboard', 'Reference', 'User', 'RestoreReference')) 'offline user only: reference + restore of the lock screen'
Assert (@($r.Items | Where-Object { $_.Id -eq 'reference' }).Count -eq 1) 'readiness explains the temporary reference'

# Nothing selected
$none = New-LPSelection -DisplayLanguage 'en-US' -RegionalFormat 'de-CH' -Keyboards @('00000807') -TargetIds @() -BlockRemoteKeyboard $false
$r = Test-LPReadiness -Snapshot (New-FakeSnapshot) -Selection $none
Assert (-not $r.CanApply -and -not $r.CanApplyReadyParts) 'nothing selected cannot be applied'

# Uninstall option
$u = New-LPSelection -DisplayLanguage 'en-US' -RegionalFormat 'de-CH' -Keyboards @('00000807') -TargetIds @('lockscreen') -UninstallOthers $true
$snap = New-FakeSnapshot -Installed @('en-US', 'de-DE', 'fr-FR') -Full @('en-US', 'de-DE', 'fr-FR')
$plan = New-LPPlan -Snapshot $snap -Selection $u -Readiness (Test-LPReadiness -Snapshot $snap -Selection $u)
$un = @($plan.Steps | Where-Object { $_.Kind -eq 'Uninstall' })[0]
Assert ((Eq $un.Languages @('de-DE', 'fr-FR')) -and -not (@($un.Languages) -contains 'en-US')) 'uninstall never removes the display language'

# ------------------------------------------------------------------------------------------------
Write-Host 'Compliance and risks'
$good = New-FakeState -Langs @('en-US') -Tips @{ 'en-US' = @('0409:00000807') } -Ui 'en-US' -Fmt 'de-CH' -Geo 223 -PreloadTips @('0409:00000807') -Sync 0
Assert (@(Test-LPStateCompliance -State $good -Selection $std -Kind 'User').Count -eq 0) 'compliant state has no issues'
$badState = New-FakeState -Langs @('de-CH', 'en-US') -Tips @{ 'de-CH' = @('0807:00000807'); 'en-US' = @('0409:00000409') } -Ui 'en-US' -Fmt 'de-CH' -Geo 223 -PreloadTips @('0807:00000807', '0409:00000409')
Assert (@(Test-LPStateCompliance -State $badState -Selection $std -Kind 'User').Count -ge 3) 'non-compliant state lists issues'
$risky = New-FakeState -Langs @('de-CH') -Tips @{ 'de-CH' = @('0807:00000807') } -Ui 'en-US' -Fmt 'de-CH' -Geo 223 -PreloadTips @('0807:00000807', '0409:00000409') -Hidden @('0409:00000409')
$risks = @(Get-LPRisks -State $risky -Kind 'User' -LockState $badState -SystemUILanguage 'en-US' -Layouts @())
Assert (@($risks | Where-Object { $_ -like '*re-adds it WITH ITS DEFAULT KEYBOARD*' }).Count -eq 1) 'risk: display language not in list'
Assert (@($risks | Where-Object { $_ -like 'Hidden layouts*' }).Count -eq 1) 'risk: hidden layouts'
Assert (@($risks | Where-Object { $_ -like 'The lock screen has layouts*' }).Count -eq 1) 'risk: lock screen layouts pulled into session'
Assert (@($risks | Where-Object { $_ -like 'Language settings sync*' }).Count -eq 1) 'risk: sync'
$lines = Get-LPStatusLines -Snapshot (New-FakeSnapshot) -Selection $std
Assert (@($lines | Where-Object { $_.Level -eq 'Risk' }).Count -gt 0) 'status shows re-add risks'
Assert ((Format-LPReportText $lines).Length -gt 100) 'status renders as text'

# ------------------------------------------------------------------------------------------------
Write-Host 'Install errors'
$codes = Get-LPHResults "Install-Language : Failed. HRESULT 0x800F0954`nother -2146498220"
Assert (Eq $codes @('0x800f0954')) 'HRESULT parsed from hex and decimal'
$e = Get-LPInstallErrorExplanation -Codes $codes -Tag 'en-US' -Build 19045
Assert ($e.Code -eq '0x800f0954' -and (@($e.Steps) -join ' ') -match 'Specify settings for optional component installation and component repair') '0x800f0954 explained with the GPO'
$e = Get-LPInstallErrorExplanation -Codes @() -Tag 'en-US' -Build 19045
Assert ((@($e.Steps) -join ' ') -match 'Add a language') 'unknown error still gives manual steps'

# ------------------------------------------------------------------------------------------------
Write-Host 'Presets'
$pr = Get-LPPresets -Path (Join-Path $PSScriptRoot '..\presets.json')
$s = Find-LPPreset $pr.Presets 'Standard'
Assert ($s -and $s.displayLanguage -eq 'en-US' -and $s.regionalFormat -eq 'de-CH' -and $s.geoId -eq 223 -and (Eq $s.keyboards @('00000807'))) 'presets.json Standard = en-US / de-CH / 223 / 00000807'
Assert (@($pr.Warnings).Count -eq 0) 'presets.json has no warnings'
$tmp = [IO.Path]::GetTempFileName()
'{ "presets": [ { "name": "Broken", "displayLanguage": "en-US", "regionalFormat": "de-CH", "keyboards": ["807"] } ] }' | Set-Content -LiteralPath $tmp
$pr = Get-LPPresets -Path $tmp
Assert ((Find-LPPreset $pr.Presets 'Standard') -and -not (Find-LPPreset $pr.Presets 'Broken') -and @($pr.Warnings).Count -eq 1) 'invalid preset skipped, built-in Standard used'
Remove-Item -LiteralPath $tmp

# ------------------------------------------------------------------------------------------------
Write-Host 'Catalogs, worker'
$cat = @(Get-LPDisplayLanguageCatalog)
Assert ($cat.Count -ge 100 -and @($cat | Where-Object { $_.Type -eq 'LP' }).Count -eq 38) "display language catalog: $($cat.Count) entries, 38 full packs"
Assert (@($cat | Group-Object Tag | Where-Object { $_.Count -gt 1 }).Count -eq 0) 'no duplicate tags'
$wt = Get-LPWorkerScriptText
Assert ($wt -match 'function Get-LPPreloadPlan' -and $wt -match 'function ConvertFrom-LPTip' -and $wt -match 'function Sync-LPLanguageBackup' -and $wt -match 'function Clear-LPCtfLeftovers' -and $wt -match 'function Read-LPRegTree' -and $wt -notmatch '#__LP_HELPERS__') 'worker contains the helper functions'
$wcalls = @([System.Management.Automation.Language.Parser]::ParseInput($wt, [ref]$null, [ref]$null).FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -like '*-LP*' } | Select-Object -Unique)
$wdefs = @([regex]::Matches($wt, '(?m)^function ([\w-]+)') | ForEach-Object { $_.Groups[1].Value })
Assert (@($wcalls | Where-Object { $wdefs -notcontains $_ }).Count -eq 0) ('every engine function the worker calls is inside the worker (missing: ' + (@($wcalls | Where-Object { $wdefs -notcontains $_ }) -join ', ') + ')')
$we = $null; $wtok = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($wt, [ref]$wtok, [ref]$we)
Assert (@($we).Count -eq 0) 'generated worker parses'
$wa = [System.Management.Automation.Language.Parser]::ParseInput($wt, [ref]$wtok, [ref]$we)
$cmdNames = @($wa.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
Assert (Eq (@('Set-WinUserLanguageList', 'Set-WinDefaultInputMethodOverride', 'Set-WinUILanguageOverride', 'Set-Culture', 'Set-WinHomeLocation') | Where-Object { $cmdNames -contains $_ }) @('Set-WinUserLanguageList', 'Set-WinDefaultInputMethodOverride', 'Set-WinUILanguageOverride', 'Set-Culture', 'Set-WinHomeLocation')) 'worker runs the full recipe'

# Worker bootstrap and failure diagnosis (in-session step blocked on a managed device)
$boot = Get-LPWorkerBootstrap -OutDir "C:\ProgramData\LanguageProfile\Jobs\a'b\out" -WorkerPath 'C:\x\worker.ps1' -JobDir 'C:\x'
$be = $null; $bt = $null
$bast = [System.Management.Automation.Language.Parser]::ParseInput($boot, [ref]$bt, [ref]$be)
Assert (@($be).Count -eq 0 -and $boot -match "a''b") 'bootstrap parses and quotes paths'
$methodCalls = @($bast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true) | ForEach-Object { $_.Extent.Text })
Assert ((Eq $methodCalls @('[scriptblock]::Create((Get-Content -LiteralPath ''C:\x\worker.ps1'' -Raw -Encoding UTF8))'))) 'bootstrap makes no .NET calls before checking the language mode (works in Constrained Language Mode)'
$tmpOut = Join-Path ([IO.Path]::GetTempPath()) ('lpfail-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmpOut
$f = Get-LPWorkerFailure -OutDir $tmpOut -Label 'PC\u' -TaskResult 'ended with result 0x00000001'
Assert ($f.Reason -like '*did not start*' -and -not $f.WorkerStarted) 'no marker: PowerShell did not start / was stopped'
Set-Content -LiteralPath (Join-Path $tmpOut 'started.txt') -Value 'started 2026-10-09T16:56:10 mode=ConstrainedLanguage'
$f = Get-LPWorkerFailure -OutDir $tmpOut -Label 'PC\u'
Assert ($f.Reason -like '*ConstrainedLanguage*' -and $f.LanguageMode -eq 'ConstrainedLanguage') 'Constrained Language Mode recognized'
Set-Content -LiteralPath (Join-Path $tmpOut 'started.txt') -Value 'started 2026-10-09T16:56:10 mode=FullLanguage'
Set-Content -LiteralPath (Join-Path $tmpOut 'bootstrap-error.txt') -Value 'This script contains malicious content and has been blocked by your antivirus software.'
$f = Get-LPWorkerFailure -OutDir $tmpOut -Label 'PC\u'
Assert ($f.Reason -like '*antivirus / AMSI*') 'antivirus block recognized'
Remove-Item -LiteralPath (Join-Path $tmpOut 'bootstrap-error.txt')
Set-Content -LiteralPath (Join-Path $tmpOut 'worker.log') -Value @('16:56:12 Step: Language list (Set-WinUserLanguageList)')
$f = Get-LPWorkerFailure -OutDir $tmpOut -Label 'PC\u'
Assert ($f.Reason -like '*stopped before it finished*Set-WinUserLanguageList*' -and $f.WorkerStarted) 'worker killed mid-way recognized'
Remove-Item -LiteralPath $tmpOut -Recurse -Force

# Dynamic scoping that Use-LPHive relies on (scriptblock sees the caller's locals inside the module)
$m = New-Module -ScriptBlock {
    function Invoke-Inner { param([scriptblock]$Action) & $Action 'x' }
    function Invoke-Outer { $local = 'seen'; Invoke-Inner -Action { param($a) "$a-$local" } }
}
Assert ((& $m { Invoke-Outer }) -eq 'x-seen') 'module scriptblock sees caller locals (Use-LPHive pattern)'

# ------------------------------------------------------------------------------------------------
Write-Host 'Real registry data (Windows 11 25H2, tests/fixtures) in a fake registry'
$fx = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\win11-25h2-registry.json')) | ConvertFrom-Json
function New-FakeHive($Entries) {
    $root = [FakeKey]::new([FakeNode]::new())
    foreach ($e in @($Entries)) {
        $k = $root.CreateSubKey([string]$e.p)
        if (-not $e.PSObject.Properties['k']) { continue }
        switch ([string]$e.k) {
            'DWord' { $d = [int]$e.d }
            'QWord' { $d = [long]$e.d }
            'MultiString' { $d = [string[]]@($e.d) }
            'Binary' { $d = [Convert]::FromBase64String([string]$e.d) }
            default { $d = [string]$e.d }
        }
        $k.SetValue([string]$e.n, $d, [string]$e.k)
    }
    return $root
}
function Get-FakeDump($Key, [string]$Prefix = '') {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($n in ($Key.GetValueNames() | Sort-Object)) { $v = $Key.GetValue($n); if ($v -is [array]) { $v = ($v -join ';') }; $lines.Add("$Prefix | $n | $($Key.Node.Kinds[$n]) | $v") }
    foreach ($s in ($Key.GetSubKeyNames() | Sort-Object)) { $lines.Add("$Prefix\$s\"); foreach ($l in (Get-FakeDump $Key.OpenSubKey($s) "$Prefix\$s")) { $lines.Add($l) } }
    return $lines.ToArray()
}
$layouts = (New-FakeSnapshot).KeyboardLayouts
$en = [int]0x409

# The user's state before: en-CH (no LCID -> transient 0x2000) with Swiss German, en-US display, US keyboard in the backup
$h = New-FakeHive $fx.userBefore
$st = Get-LPHiveState -Base $h -Root '' -Layouts $layouts
Assert ((Eq $st.Languages @('en-CH')) -and $st.LangIds['en-CH'] -eq 0x2000) 'real data: en-CH uses transient language ID 0x2000'
Assert (Eq $st.Tips @('2000:00000807')) 'real data: Swiss German on en-CH = 2000:00000807'
Assert ((Eq $st.PreloadTips @('2000:00000807')) -and @($st.Hidden).Count -eq 0) 'real data: Preload 00002000 + Substitute -> 00000807 resolved'
Assert ((Eq $st.BackupLanguages @('en-US')) -and (Eq $st.BackupTips @('0409:00000409'))) 'real data: backup still holds en-US with the US keyboard'
Assert ((@($st.CtfForeignLangIds) -contains 0x809) -and (@($st.CtfForeignLangIds) -contains 0x409)) 'real data: CTF leftovers for en-GB (0x809) and en-US detected'
$risks = @(Get-LPRisks -State $st -Kind 'User' -SystemUILanguage 'en-US' -Layouts $layouts)
Assert (@($risks | Where-Object { $_ -like '*re-adds it WITH ITS DEFAULT KEYBOARD*' }).Count -eq 1) 'real data: en-US display not in list -> re-add risk'
Assert (@($risks | Where-Object { $_ -like "Windows' backup of the language list*US*" }).Count -eq 1) 'real data: backup with US keyboard -> risk'
Assert (@($risks | Where-Object { $_ -like 'Text input settings (CTF)*en-GB*' }).Count -eq 1) 'real data: CTF leftover en-GB -> risk'

$std = New-LPSelection -DisplayLanguage 'en-US' -RegionalFormat 'de-CH' -GeoId 223 -Keyboards @('00000807') -TargetIds @('lockscreen', 'newusers')

# What Windows' recipe alone leaves behind in the user's hive, then the tool's extra cleanup
$h = New-FakeHive $fx.userAfterRecipe
$st = Get-LPHiveState -Base $h -Root '' -Layouts $layouts
Assert ($st.UILanguage -eq 'en-US' -and $st.UILanguageOverride -eq 'en-US') 'real data: display language read from User Profile\WindowsOverride'
Assert ((Eq $st.Preload @('00000409')) -and $st.Substitutes['00000409'] -eq '00000807' -and (Eq $st.PreloadTips @('0409:00000807'))) 'real data: Windows writes Preload 00000409 + Substitute 00000409 -> 00000807'
$iss = @(Test-LPStateCompliance -State $st -Selection $std -Kind 'User')
Assert ((@($iss | Where-Object { $_ -like 'language list backup*' }).Count -eq 1) -and (@($iss | Where-Object { $_ -like 'text input (CTF)*' }).Count -eq 1) -and $iss.Count -eq 2) "real data: after Windows' recipe only backup + CTF differ ($($iss -join ' / '))"
$pp = Get-LPPreloadPlan -DesiredTips $std.Tips -Preload $st.Preload -Substitutes $st.Substitutes
Assert ((Eq $pp.Preload @('00000409')) -and $pp.Substitutes['00000409'] -eq '00000807' -and @($pp.Removed).Count -eq 0) "Preload cleanup keeps Windows' own entry"
$removed = @(Clear-LPCtfLeftovers -Base $h -Root '' -LangIds @($en))
Assert ((@($removed | Where-Object { $_ -like '*AssemblyItem\0x00000809' }).Count -eq 1) -and (@($removed | Where-Object { $_ -like '*AssemblyItem\0x00002000' }).Count -eq 1)) 'CTF cleanup removes en-GB and the old en-CH entries'
Assert (Sync-LPLanguageBackup -Base $h -Root '') 'backup sync ran'
$st = Get-LPHiveState -Base $h -Root '' -Layouts $layouts
Assert (@(Test-LPStateCompliance -State $st -Selection $std -Kind 'User').Count -eq 0) 'real data: user compliant after recipe + backup sync + CTF cleanup'
Assert (-not $h.OpenSubKey('Control Panel\International\User Profile System Backup').GetValue('WindowsOverride')) 'backup does not get the override values'
Assert (@(Clear-LPCtfLeftovers -Base $h -Root '' -LangIds @($en)).Count -eq 0) 'CTF cleanup is idempotent'

# Lock screen: SYSTEM recipe result -> cleanup -> reference -> copied into the real Default profile
$lock = New-FakeHive $fx.lockAfterSystemRecipe
$st = Get-LPHiveState -Base $lock -Root '' -Layouts $layouts
Assert ((Eq $st.BackupLanguages @('en-CH', 'en-US')) -and (@($st.BackupTips) -contains '0409:00000409')) "real data: lock screen backup still has en-CH + US keyboard after Windows' recipe"
$null = Clear-LPCtfLeftovers -Base $lock -Root '' -LangIds @($en)
$null = Sync-LPLanguageBackup -Base $lock -Root ''
$st = Get-LPHiveState -Base $lock -Root '' -Layouts $layouts
Assert (@(Test-LPStateCompliance -State $st -Selection $std -Kind 'LockScreen' -SystemUILanguage 'en-US').Count -eq 0) 'real data: lock screen reference compliant'
$reference = @(Get-LPLanguageKeySet | ForEach-Object { Get-LPKeySnapshot -Base $lock -Root '' -Spec $_ })

$def = New-FakeHive $fx.defaultProfileBefore
$defBefore = Get-FakeDump $def
$snapJson = @((@(Get-LPLanguageKeySet) + @(Get-LPSyncKeySpec)) | ForEach-Object { Get-LPKeySnapshot -Base $def -Root '' -Spec $_ }) | ConvertTo-Json -Depth 40
$st = Get-LPHiveState -Base $def -Root '' -Layouts $layouts
Assert ((@($st.CtfForeignLangIds) -contains 0x809) -and (Eq $st.PreloadTips @('0409:00000807', '0409:00000409'))) 'real data: Default profile has en-GB CTF leftover and the US keyboard'
Copy-LPReferenceToHive -Base $def -Root '' -Reference $reference -DisableSync $true
$st = Get-LPHiveState -Base $def -Root '' -Layouts $layouts
Assert (@(Test-LPStateCompliance -State $st -Selection $std -Kind 'NewUsers').Count -eq 0) "real data: Default profile compliant after the copy ($(@(Test-LPStateCompliance -State $st -Selection $std -Kind 'NewUsers') -join ' / '))"
Assert ($def.OpenSubKey('Control Panel\Desktop').GetValue('WallPaper') -eq 'C:\Windows\Web\Wallpaper\Windows\img0.jpg') 'copy leaves other Control Panel\Desktop values alone'
Assert (Eq ($def.OpenSubKey('Control Panel\Desktop').GetValue('PreferredUILanguagesPending')) @('en-US')) 'copy sets the pending display language'
$intlSubs = @($def.OpenSubKey('Control Panel\International').GetSubKeyNames())
Assert ((@($intlSubs | Where-Object { $_ -match '^[^\x00-\x7F]+$' }).Count -eq 1)) 'copy leaves the calendar subkey of International alone'

# Restore from the JSON manifest form brings the Default profile back exactly
$snaps = @($snapJson | ConvertFrom-Json)
foreach ($sn in $snaps) { Set-LPKeyFromSnapshot -Base $def -Root '' -Snapshot $sn }
$defAfter = Get-FakeDump $def
$diff = @(Compare-Object $defBefore $defAfter)
$diff | Select-Object -First 10 | ForEach-Object { Write-Host ("    " + $_.SideIndicator + " " + $_.InputObject) }
Assert ($diff.Count -eq 0) "restore from manifest JSON is exact ($($diff.Count) differences)"
$lines = Get-LPStateLines -State (Get-LPHiveState -Base (New-FakeHive $fx.userBefore) -Root '' -Layouts $layouts) -Layouts $layouts -SystemUILanguage 'en-US'
Assert (@($lines | Where-Object { $_.Text -like 'List backup:*US*' }).Count -eq 1 -and @($lines | Where-Object { $_.Text -like 'Text input (CTF):*en-GB*' }).Count -eq 1) 'status shows the backup and CTF entries'

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 }
exit 0
