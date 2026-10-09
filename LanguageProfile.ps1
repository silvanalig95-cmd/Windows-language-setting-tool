#Requires -Version 5.1
<#
.SYNOPSIS
    Language Profile - standardizes display language, regional format and keyboard layouts on a Windows PC.

.DESCRIPTION
    Without parameters the WPF front-end starts. With -Preset (or any of the CLI parameters below) the
    tool runs unattended, e.g. from Intune/SCCM as SYSTEM.

    The tool applies exactly one display language, one regional format and one or more keyboard layouts
    to the selected user accounts, the lock/welcome screen (and system accounts) and the new-user template
    (Default profile), and removes every other language and keyboard from those places. See README.md.

    Exit codes:
        0     Done
        3010  Done, restart needed
        2     Blocked by a missing prerequisite - nothing was changed
        4     Partially applied (only possible with -ApplyReadyParts; the summary lists what was skipped)
        5     -Verify only: the PC does not match the selected profile
        1     Error

.PARAMETER Preset
    Name of a preset in presets.json, e.g. Standard. Fields given explicitly override the preset.
.PARAMETER DisplayLanguage
    Display language tag, e.g. en-US.
.PARAMETER RegionalFormat
    Regional format (specific culture), e.g. de-CH.
.PARAMETER GeoId
    Country/region GeoId, e.g. 223 (Switzerland). Default: the GeoId of the regional format.
.PARAMETER Keyboard
    One or more keyboard layout IDs (8 hex digits), e.g. 00000807. The first one is the default.
.PARAMETER Target
    SignedIn, AllUsers, LockScreen, NewUsers, a SID or an account name (DOMAIN\user or user).
    Default: SignedIn,LockScreen,NewUsers.
.PARAMETER KeepLanguageSync
    Do not disable language settings sync for the targets (default: sync is disabled).
.PARAMETER AllowRemoteKeyboardLayout
    Do not set IgnoreRemoteKeyboardLayout=1 (default: RDP keyboard injection is blocked).
.PARAMETER SetSystemLocale
    Also set the system locale for non-Unicode programs (restart needed). Uses -SystemLocale or the regional format.
.PARAMETER UninstallOtherLanguages
    Uninstall every other installed language pack (never the display language being applied).
.PARAMETER LanguageSource
    Folder that contains the language pack CAB from the "Languages and Optional Features" ISO.
    When set, the pack is installed from there (DISM) instead of Windows Update/WSUS.
.PARAMETER ApplyReadyParts
    If some prerequisites are blocked, apply the parts that are ready anyway (exit code 4).
.PARAMETER Preview
    Show the readiness check and the preview, change nothing.
.PARAMETER Status
    Show the current state of every profile (read-only).
.PARAMETER Verify
    Check whether the targets match the profile. Exit 0 = compliant, 5 = not compliant.
.PARAMETER Json
    With -Status/-Preview/-Verify: write JSON instead of text.
.PARAMETER Restore
    Restore a backup: a backup folder path or "Latest".
.PARAMETER NoUI
    Force CLI mode.
.PARAMETER Gui
    Force the GUI (e.g. -Gui -Preset Standard preselects a preset).

.EXAMPLE
    LanguageProfile.cmd
.EXAMPLE
    LanguageProfile.cmd -Preset Standard
.EXAMPLE
    LanguageProfile.cmd -Preset Standard -Target AllUsers,LockScreen,NewUsers -Preview
#>
[CmdletBinding()]
param(
    [string]$Preset,
    [string]$DisplayLanguage,
    [string]$RegionalFormat,
    [int]$GeoId = 0,
    [string[]]$Keyboard,
    [string[]]$Target,
    [switch]$KeepLanguageSync,
    [switch]$AllowRemoteKeyboardLayout,
    [switch]$SetSystemLocale,
    [string]$SystemLocale,
    [switch]$UninstallOtherLanguages,
    [string]$LanguageSource,
    [switch]$ApplyReadyParts,
    [switch]$Preview,
    [switch]$Status,
    [switch]$Verify,
    [switch]$Json,
    [string]$Restore,
    [switch]$NoUI,
    [switch]$Gui,
    [ValidateRange(1, 120)][int]$TaskTimeoutMinutes = 10,
    [switch]$Elevated
)

# ------------------------------------------------------------------------------------------------
# 0. Guards that must run before anything else
# ------------------------------------------------------------------------------------------------
if (-not $PSVersionTable.ContainsKey('PSEdition') -or $PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    [Console]::Error.WriteLine(('Language Profile must run in Windows PowerShell 5.1 (powershell.exe). This is PowerShell {0} ({1}). ' +
        'The International module cmdlets misbehave in PowerShell 7. Start the tool with LanguageProfile.cmd.') -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
    exit 1
}

# ================================================================================================
# 1. ENGINE (no UI code). Loaded as a dynamic module, also inside background runspaces.
# ================================================================================================
$LPEngineScript = {
    Set-StrictMode -Off
    $ErrorActionPreference = 'Stop'

    $script:LPVersion       = '1.0.0'
    $script:ScriptRoot      = $null
    $script:DataRoot        = $null
    $script:LogFile         = $null
    $script:LogQueue        = $null
    $script:LogToConsole    = $false
    $script:CurrentBackup   = $null
    $script:DisplayCatalog  = $null
    $script:TaskPath        = '\LanguageProfile\'
    $script:HiveMountPrefix = 'LanguageProfile_'

    $script:ExitCodes = @{ Done = 0; Error = 1; Blocked = 2; Partial = 4; NotCompliant = 5; RestartNeeded = 3010 }

    $script:FavoriteFormats = @('de-CH', 'en-CH', 'fr-CH', 'it-CH', 'en-GB', 'en-US', 'de-DE')

    # Built-in fallback so the one-click path works even if presets.json is missing or broken.
    $script:BuiltInStandardPreset = [pscustomobject]@{
        name            = 'Standard'
        description     = 'English (United States) display, German (Switzerland) formats, Swiss German keyboard'
        displayLanguage = 'en-US'
        regionalFormat  = 'de-CH'
        geoId           = 223
        keyboards       = @('00000807')
        systemLocale    = $null
    }

    # The registry keys the tool replaces in every user-type hive (target users, HKU\.DEFAULT,
    # S-1-5-19, S-1-5-20 and the Default profile). Paths are relative to the hive root.
    #   Tree   = the whole key incl. subkeys is replaced
    #   Values = all values of the key are replaced, subkeys are left alone
    #   Value  = only the listed values are replaced (absent in the source = deleted in the target)
    # Keep this table in sync with README.md ("Registry keys touched"). Confirmed by the registry diff on
    # Windows 11 25H2 (build 26200): the recipe and Microsoft's own copy write exactly these keys (plus
    # caches that Windows rebuilds itself: MuiCache, Spelling, TabletTip, CloudStore, IE AcceptLanguage).
    $script:LanguageKeySet = @(
        [pscustomobject]@{ Id = 'International';     Path = 'Control Panel\International';                             Mode = 'Values'; Names = $null }
        [pscustomobject]@{ Id = 'UserProfile';       Path = 'Control Panel\International\User Profile';                Mode = 'Tree';   Names = $null }
        [pscustomobject]@{ Id = 'UserProfileBackup'; Path = 'Control Panel\International\User Profile System Backup';  Mode = 'Tree';   Names = $null }
        [pscustomobject]@{ Id = 'Geo';               Path = 'Control Panel\International\Geo';                         Mode = 'Tree';   Names = $null }
        [pscustomobject]@{ Id = 'DesktopUILanguage'; Path = 'Control Panel\Desktop';                                   Mode = 'Value';  Names = @('PreferredUILanguages', 'PreferredUILanguagesPending', 'PreviousPreferredUILanguages') }
        [pscustomobject]@{ Id = 'MuiCached';         Path = 'Control Panel\Desktop\MuiCached';                         Mode = 'Tree';   Names = $null }
        [pscustomobject]@{ Id = 'Preload';           Path = 'Keyboard Layout\Preload';                                 Mode = 'Tree';   Names = $null }
        [pscustomobject]@{ Id = 'Substitutes';       Path = 'Keyboard Layout\Substitutes';                             Mode = 'Tree';   Names = $null }
        [pscustomobject]@{ Id = 'CtfSortOrder';      Path = 'Software\Microsoft\CTF\SortOrder';                         Mode = 'Tree';   Names = $null }
        [pscustomobject]@{ Id = 'CtfAssemblies';     Path = 'Software\Microsoft\CTF\Assemblies';                        Mode = 'Tree';   Names = $null }
    )
    $script:SyncKeySpec = [pscustomobject]@{ Id = 'LanguageSync'; Path = 'Software\Microsoft\Windows\CurrentVersion\SettingSync\Groups\Language'; Mode = 'Value'; Names = @('Enabled') }
    $script:RemoteKbSpec = [pscustomobject]@{ Id = 'IgnoreRemoteKeyboardLayout'; Path = 'SYSTEM\CurrentControlSet\Control\Keyboard Layout'; Mode = 'Value'; Names = @('IgnoreRemoteKeyboardLayout') }

    # Windows display languages (Microsoft: "Available languages for Windows").
    # Tag | English name | Type | Required base language(s)
    #   LP     = full language pack (CAB + LXP); Install-Language can install it
    #   LIPCAB = language interface pack that also ships as a CAB on Windows 11
    #   LIP    = language interface pack, Local Experience Pack (Microsoft Store) only
    $script:DisplayLanguageTable = @'
ar-SA|Arabic (Saudi Arabia)|LP|
bg-BG|Bulgarian (Bulgaria)|LP|
zh-CN|Chinese (Simplified, China)|LP|
zh-TW|Chinese (Traditional, Taiwan)|LP|
hr-HR|Croatian (Croatia)|LP|
cs-CZ|Czech (Czechia)|LP|
da-DK|Danish (Denmark)|LP|
nl-NL|Dutch (Netherlands)|LP|
en-US|English (United States)|LP|
en-GB|English (United Kingdom)|LP|
et-EE|Estonian (Estonia)|LP|
fi-FI|Finnish (Finland)|LP|
fr-CA|French (Canada)|LP|
fr-FR|French (France)|LP|
de-DE|German (Germany)|LP|
el-GR|Greek (Greece)|LP|
he-IL|Hebrew (Israel)|LP|
hu-HU|Hungarian (Hungary)|LP|
it-IT|Italian (Italy)|LP|
ja-JP|Japanese (Japan)|LP|
ko-KR|Korean (Korea)|LP|
lv-LV|Latvian (Latvia)|LP|
lt-LT|Lithuanian (Lithuania)|LP|
nb-NO|Norwegian Bokmal (Norway)|LP|
pl-PL|Polish (Poland)|LP|
pt-BR|Portuguese (Brazil)|LP|
pt-PT|Portuguese (Portugal)|LP|
ro-RO|Romanian (Romania)|LP|
ru-RU|Russian (Russia)|LP|
sr-Latn-RS|Serbian (Latin, Serbia)|LP|
sk-SK|Slovak (Slovakia)|LP|
sl-SI|Slovenian (Slovenia)|LP|
es-MX|Spanish (Mexico)|LP|
es-ES|Spanish (Spain)|LP|
sv-SE|Swedish (Sweden)|LP|
th-TH|Thai (Thailand)|LP|
tr-TR|Turkish (Turkey)|LP|
uk-UA|Ukrainian (Ukraine)|LP|
af-ZA|Afrikaans (South Africa)|LIP|en-US;en-GB
sq-AL|Albanian (Albania)|LIP|en-US;en-GB
am-ET|Amharic (Ethiopia)|LIP|en-US
hy-AM|Armenian (Armenia)|LIP|en-US;ru-RU
as-IN|Assamese (India)|LIP|en-US
az-Latn-AZ|Azerbaijani (Latin, Azerbaijan)|LIP|en-US;ru-RU
bn-BD|Bangla (Bangladesh)|LIP|en-US
bn-IN|Bangla (India)|LIP|en-US
eu-ES|Basque (Spain)|LIPCAB|es-ES
be-BY|Belarusian (Belarus)|LIP|ru-RU
bs-Latn-BA|Bosnian (Latin, Bosnia and Herzegovina)|LIP|en-US;hr-HR;sr-Latn-RS
ca-ES|Catalan (Spain)|LIPCAB|es-ES;fr-FR
ca-ES-valencia|Valencian (Spain)|LIP|es-ES
ku-Arab-IQ|Central Kurdish (Iraq)|LIP|en-US
chr-Cher-US|Cherokee (United States)|LIP|en-US
prs-AF|Dari (Afghanistan)|LIP|en-US
fil-PH|Filipino (Philippines)|LIP|en-US
gl-ES|Galician (Spain)|LIPCAB|es-ES
ka-GE|Georgian (Georgia)|LIP|en-US;ru-RU
gu-IN|Gujarati (India)|LIP|en-US
ha-Latn-NG|Hausa (Latin, Nigeria)|LIP|en-US;fr-FR
hi-IN|Hindi (India)|LIP|en-US
is-IS|Icelandic (Iceland)|LIP|en-US
ig-NG|Igbo (Nigeria)|LIP|en-US
id-ID|Indonesian (Indonesia)|LIPCAB|en-US
ga-IE|Irish (Ireland)|LIP|en-US;en-GB
xh-ZA|isiXhosa (South Africa)|LIP|en-US
zu-ZA|isiZulu (South Africa)|LIP|en-US
kn-IN|Kannada (India)|LIP|en-US
kk-KZ|Kazakh (Kazakhstan)|LIP|en-US;ru-RU
km-KH|Khmer (Cambodia)|LIP|en-US
quc-Latn-GT|K'iche' (Guatemala)|LIP|es-MX
rw-RW|Kinyarwanda (Rwanda)|LIP|en-US
sw-KE|Kiswahili (Kenya)|LIP|en-US
kok-IN|Konkani (India)|LIP|en-US
ky-KG|Kyrgyz (Kyrgyzstan)|LIP|ru-RU
lo-LA|Lao (Laos)|LIP|en-US
lb-LU|Luxembourgish (Luxembourg)|LIP|fr-FR;de-DE
mk-MK|Macedonian (North Macedonia)|LIP|en-US
ms-MY|Malay (Malaysia)|LIP|en-US;en-GB
ml-IN|Malayalam (India)|LIP|en-US
mt-MT|Maltese (Malta)|LIP|en-US;en-GB
mi-NZ|Maori (New Zealand)|LIP|en-US;en-GB
mr-IN|Marathi (India)|LIP|en-US
mn-MN|Mongolian (Cyrillic, Mongolia)|LIP|en-US;ru-RU
ne-NP|Nepali (Nepal)|LIP|en-US
nn-NO|Norwegian Nynorsk (Norway)|LIP|nb-NO
or-IN|Odia (India)|LIP|en-US
fa-IR|Persian (Iran)|LIP|en-US
pa-IN|Punjabi (Gurmukhi, India)|LIP|en-US
pa-Arab-PK|Punjabi (Arabic, Pakistan)|LIP|en-US
quz-PE|Quechua (Peru)|LIP|es-MX;es-ES
gd-GB|Scottish Gaelic (United Kingdom)|LIP|en-US;en-GB
sr-Cyrl-BA|Serbian (Cyrillic, Bosnia and Herzegovina)|LIP|en-US;sr-Latn-RS
sr-Cyrl-RS|Serbian (Cyrillic, Serbia)|LIP|sr-Latn-RS;en-US
nso-ZA|Sesotho sa Leboa (South Africa)|LIP|en-US
tn-ZA|Setswana (South Africa)|LIP|en-US
sd-Arab-PK|Sindhi (Arabic, Pakistan)|LIP|en-US
si-LK|Sinhala (Sri Lanka)|LIP|en-US
tg-Cyrl-TJ|Tajik (Cyrillic, Tajikistan)|LIP|ru-RU
ta-IN|Tamil (India)|LIP|en-US
tt-RU|Tatar (Russia)|LIP|ru-RU
te-IN|Telugu (India)|LIP|en-US
ti-ET|Tigrinya (Ethiopia)|LIP|en-US
tk-TM|Turkmen (Turkmenistan)|LIP|en-US;ru-RU
ur-PK|Urdu (Pakistan)|LIP|en-US
ug-CN|Uyghur (China)|LIP|zh-CN;en-US
uz-Latn-UZ|Uzbek (Latin, Uzbekistan)|LIP|en-US;ru-RU
vi-VN|Vietnamese (Vietnam)|LIPCAB|en-US
cy-GB|Welsh (United Kingdom)|LIP|en-US;en-GB
wo-SN|Wolof (Senegal)|LIP|fr-FR
yo-NG|Yoruba (Nigeria)|LIP|en-US
'@

    # Known language policies: value name -> how it affects the result.
    #   Effect: BlockPack | BlockUi | BlockFormat | BlockGeo | Info | Warn
    $script:PolicyCatalog = @{
        'RestrictLanguagePacksAndFeaturesInstall'  = @{ Effect = 'BlockPack';   Setting = 'Computer Configuration > Administrative Templates > Control Panel > Regional and Language Options > Restrict Language Pack and Language Feature Installation' }
        'BlockCleanupOfUnusedPreinstalledLangPacks' = @{ Effect = 'Info';       Setting = 'Computer Configuration > Administrative Templates > Control Panel > Regional and Language Options > Block cleanup of unused language packs' }
        'PreferredUILanguages'                     = @{ Effect = 'BlockUi';     Setting = 'Administrative Templates > Control Panel > Regional and Language Options > Restricts the UI language(s) Windows uses (computer: "for all logged users", user: "for the selected user")' }
        'MultiUILanguageID'                        = @{ Effect = 'BlockUi';     Setting = 'User Configuration > Administrative Templates > Control Panel > Regional and Language Options > Restrict selection of Windows menus and dialogs language' }
        'MachineUILock'                            = @{ Effect = 'Warn';        Setting = 'Computer Configuration > Administrative Templates > Control Panel > Regional and Language Options > Force selected system UI language to overwrite the user UI language' }
        'MachineUILanguageOverwrite'               = @{ Effect = 'Warn';        Setting = 'Intune: Time Language Settings > Machine UI Language Overwrite' }
        'RestrictUserLocales'                      = @{ Effect = 'BlockFormat'; Setting = 'Administrative Templates > System > Locale Services > Restrict user locales' }
        'AllowableUserLocaleTagsList'              = @{ Effect = 'BlockFormat'; Setting = 'Administrative Templates > System > Locale Services > Restrict user locales' }
        'PreventGeoIdChange'                       = @{ Effect = 'BlockGeo';    Setting = 'Administrative Templates > System > Locale Services > Disallow changing geographic location' }
        'PreventUserOverrides'                     = @{ Effect = 'Info';        Setting = 'Administrative Templates > System > Locale Services > Disallow user override of locale settings' }
        'BlockUserInputMethodsForSignIn'           = @{ Effect = 'Info';        Setting = 'Computer Configuration > Administrative Templates > System > Locale Services > Disallow copying of user input methods to the system account for sign-in' }
    }

    # --------------------------------------------------------------------------------------------
    # Initialization and logging
    # --------------------------------------------------------------------------------------------
    function Initialize-LPEngine {
        param(
            [string]$ScriptRoot,
            [string]$DataRoot,
            $LogQueue,
            [switch]$Console,
            [string]$LogFile,
            [string]$LogName = 'Session'
        )
        $script:ScriptRoot = $ScriptRoot
        if ($DataRoot) { $script:DataRoot = $DataRoot } else { $script:DataRoot = Join-Path $env:ProgramData 'LanguageProfile' }
        $script:LogQueue = $LogQueue
        $script:LogToConsole = [bool]$Console
        Initialize-LPDataRoot
        if ($LogFile) { $script:LogFile = $LogFile } else { $script:LogFile = New-LPLogFile -Name $LogName }
        return $script:LogFile
    }

    function Initialize-LPDataRoot {
        $root = $script:DataRoot
        if (-not (Test-Path -LiteralPath $root)) {
            $null = New-Item -ItemType Directory -Path $root -Force
            # Only SYSTEM and Administrators: logs and backups contain user names and profile data.
            $r = Invoke-LPNative -FilePath (Join-Path $env:SystemRoot 'System32\icacls.exe') -Arguments @($root, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
            if ($r.ExitCode -ne 0) { Write-LPLog "Could not restrict the permissions of $root : $($r.Output)" -Level Warn }
        }
        foreach ($d in 'Logs', 'Backups', 'Jobs') {
            $p = Join-Path $root $d
            if (-not (Test-Path -LiteralPath $p)) { $null = New-Item -ItemType Directory -Path $p -Force }
        }
    }

    function New-LPLogFile {
        param([string]$Name = 'Run')
        $dir = Join-Path $script:DataRoot 'Logs'
        $file = Join-Path $dir ('LanguageProfile_{0:yyyyMMdd-HHmmss}_{1}_{2}.log' -f (Get-Date), $Name, $PID)
        $header = 'Language Profile {0} - {1} - computer {2} - running as {3} - PowerShell {4}' -f $script:LPVersion, $Name, $env:COMPUTERNAME, [Security.Principal.WindowsIdentity]::GetCurrent().Name, $PSVersionTable.PSVersion
        try { [IO.File]::WriteAllText($file, $header + "`r`n", (New-Object Text.UTF8Encoding($true))) } catch { }
        return $file
    }

    function Set-LPLogFile {
        param([string]$Path)
        $script:LogFile = $Path
    }

    function Get-LPLogFile { return $script:LogFile }
    function Get-LPDataRoot { return $script:DataRoot }
    function Get-LPVersion { return $script:LPVersion }
    function Get-LPExitCodes { return $script:ExitCodes }
    function Get-LPLanguageKeySet { return $script:LanguageKeySet }
    function Get-LPSyncKeySpec { return $script:SyncKeySpec }

    function Write-LPLog {
        param(
            [Parameter(Position = 0)][AllowEmptyString()][string]$Message,
            [ValidateSet('Info', 'Step', 'OK', 'Warn', 'Error', 'Detail')][string]$Level = 'Info'
        )
        $line = '{0:yyyy-MM-dd HH:mm:ss} {1,-6} {2}' -f (Get-Date), $Level.ToUpperInvariant(), $Message
        if ($script:LogFile) {
            for ($i = 0; $i -lt 3; $i++) {
                try { [IO.File]::AppendAllText($script:LogFile, $line + "`r`n", [Text.Encoding]::UTF8); break } catch { Start-Sleep -Milliseconds 50 }
            }
        }
        if ($script:LogQueue) {
            $script:LogQueue.Enqueue($line)
        }
        elseif ($script:LogToConsole) {
            $color = switch ($Level) { 'Step' { 'Cyan' } 'OK' { 'Green' } 'Warn' { 'Yellow' } 'Error' { 'Red' } 'Detail' { 'DarkGray' } default { 'Gray' } }
            Write-Host $line -ForegroundColor $color
        }
    }

    # Runs a native command without letting stderr turn into a terminating error (PS 5.1 trap).
    function Invoke-LPNative {
        param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @())
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = & $FilePath @Arguments 2>&1 | ForEach-Object { "$_" }
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $eap }
        return [pscustomobject]@{ ExitCode = $code; Output = (@($out) -join "`n").Trim() }
    }

    function Invoke-LPReg {
        param([Parameter(Mandatory)][string[]]$Arguments)
        Invoke-LPNative -FilePath (Join-Path $env:SystemRoot 'System32\reg.exe') -Arguments $Arguments
    }

    # --------------------------------------------------------------------------------------------
    # Small pure helpers
    # --------------------------------------------------------------------------------------------
    function Get-LPCultureInfo {
        param([string]$Name)
        if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
        try { return [Globalization.CultureInfo]::GetCultureInfo($Name.Trim()) } catch { return $null }
    }

    function Get-LPLcid {
        param([string]$Tag)
        $c = Get-LPCultureInfo $Tag
        if ($c) { return [int]$c.LCID }
        return 0
    }

    function ConvertTo-LPLayoutId {
        param([string]$Id)
        if ($null -eq $Id) { return $null }
        $t = $Id.Trim()
        if ($t -notmatch '^[0-9A-Fa-f]{8}$') { return $null }
        return $t.ToUpperInvariant()
    }

    function ConvertTo-LPTip {
        param([int]$Lcid, [string]$LayoutId)
        return ('{0:X4}:{1}' -f $Lcid, $LayoutId.ToUpperInvariant())
    }

    function ConvertFrom-LPTip {
        param([string]$Tip)
        if ($Tip -match '^([0-9A-Fa-f]{4}):(.+)$') {
            $lang = $Matches[1].ToUpperInvariant()
            $layout = $Matches[2].ToUpperInvariant()
            return [pscustomobject]@{ Lang = $lang; Layout = $layout; Tip = ('{0}:{1}' -f $lang, $layout) }
        }
        return $null
    }

    # Computes the new Keyboard Layout\Preload + Substitutes so that only entries resolving to the
    # desired tips remain, in the desired order (first = default), renumbered 1..n.
    #   $Preload     : Preload values in order ("1","2",...)
    #   $Substitutes : hashtable name -> value of Keyboard Layout\Substitutes
    # A Preload value is a KLID whose low word is the language ID. If the layout differs from the
    # language (e.g. Swiss German on en-US), Windows writes d0NN<lang> and maps it in Substitutes.
    function Get-LPPreloadPlan {
        param([string[]]$DesiredTips, [object[]]$Preload, [hashtable]$Substitutes)
        $subs = @{}
        if ($Substitutes) {
            foreach ($k in @($Substitutes.Keys)) { $subs[([string]$k).ToLowerInvariant()] = ([string]$Substitutes[$k]).Trim().ToUpperInvariant() }
        }
        $desired = New-Object System.Collections.Generic.List[string]
        foreach ($t in @($DesiredTips)) {
            if (-not $t) { continue }
            $d = ConvertFrom-LPTip $t
            if ($d -and -not $desired.Contains($d.Tip)) { $desired.Add($d.Tip) }
        }
        $entries = New-Object System.Collections.Generic.List[object]
        foreach ($v in @($Preload)) {
            if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v)) { continue }
            $raw = ([string]$v).Trim()
            $klid = $raw.ToLowerInvariant()
            if ($klid -notmatch '^[0-9a-f]{8}$') {
                $entries.Add([pscustomobject]@{ Value = $raw; Lang = $null; Layout = $null; Tip = $null; Valid = $false; Substituted = $false })
                continue
            }
            $lang = $klid.Substring(4).ToUpperInvariant()
            $isSub = $subs.ContainsKey($klid)
            if ($isSub) { $layout = $subs[$klid] } else { $layout = $klid.ToUpperInvariant() }
            $entries.Add([pscustomobject]@{ Value = $raw; Lang = $lang; Layout = $layout; Tip = ('{0}:{1}' -f $lang, $layout); Valid = $true; Substituted = $isSub })
        }
        $keep = @{}
        $removed = New-Object System.Collections.Generic.List[object]
        foreach ($e in $entries) {
            if ($e.Valid -and $desired.Contains($e.Tip) -and -not $keep.ContainsKey($e.Tip)) { $keep[$e.Tip] = $e }
            else { $removed.Add($e) }
        }
        $used = @{}
        foreach ($e in $keep.Values) { $used[$e.Value.ToLowerInvariant()] = $true }
        $newPreload = New-Object System.Collections.Generic.List[string]
        $newSubs = [ordered]@{}
        $added = New-Object System.Collections.Generic.List[string]
        foreach ($tip in $desired) {
            if ($keep.ContainsKey($tip)) {
                $e = $keep[$tip]
                $newPreload.Add($e.Value)
                if ($e.Layout -ne $e.Value.ToUpperInvariant()) { $newSubs[$e.Value] = $e.Layout }
                continue
            }
            $p = ConvertFrom-LPTip $tip
            $langLower = $p.Lang.ToLowerInvariant()
            $val = $null
            $plain = ('0000' + $p.Lang).ToLowerInvariant()
            if ($p.Layout -eq ('0000' + $p.Lang) -and -not $used.ContainsKey($plain)) {
                $val = $plain
            }
            else {
                foreach ($k in @($subs.Keys | Sort-Object)) {
                    if ($k.EndsWith($langLower) -and $subs[$k] -eq $p.Layout -and -not $used.ContainsKey($k)) { $val = $k; break }
                }
                if (-not $val) {
                    for ($n = 1; $n -le 0xFFF; $n++) {
                        $cand = 'd{0:x3}{1}' -f $n, $langLower
                        if (-not $subs.ContainsKey($cand) -and -not $used.ContainsKey($cand)) { $val = $cand; break }
                    }
                }
            }
            $used[$val] = $true
            $newPreload.Add($val)
            if ($p.Layout -ne $val.ToUpperInvariant()) { $newSubs[$val] = $p.Layout }
            $added.Add($tip)
        }
        return [pscustomobject]@{
            Preload     = $newPreload.ToArray()
            Substitutes = $newSubs
            Removed     = $removed.ToArray()
            Added       = $added.ToArray()
            Entries     = $entries.ToArray()
        }
    }

    function Get-LPDisplayLanguageCatalog {
        if ($script:DisplayCatalog) { return $script:DisplayCatalog }
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($line in ($script:DisplayLanguageTable -split "`r?`n")) {
            $l = $line.Trim()
            if (-not $l -or $l.StartsWith('#')) { continue }
            $p = $l.Split('|')
            $base = @()
            if ($p.Count -gt 3 -and $p[3]) { $base = @($p[3].Split(';') | Where-Object { $_ }) }
            $list.Add([pscustomobject]@{ Tag = $p[0]; Name = $p[1]; Type = $p[2]; Base = $base })
        }
        $script:DisplayCatalog = @($list | Sort-Object Name)
        return $script:DisplayCatalog
    }

    function Find-LPDisplayLanguage {
        param([string]$Tag)
        foreach ($c in (Get-LPDisplayLanguageCatalog)) { if ($c.Tag -eq $Tag) { return $c } }
        return $null
    }

    function Get-LPFormatCatalog {
        $fav = $script:FavoriteFormats
        $all = [Globalization.CultureInfo]::GetCultures([Globalization.CultureTypes]::SpecificCultures)
        $items = foreach ($c in $all) {
            if (-not $c.Name) { continue }
            $favIndex = [array]::IndexOf($fav, $c.Name)
            [pscustomobject]@{ Name = $c.Name; EnglishName = $c.EnglishName; Display = ('{0}  -  {1}' -f $c.EnglishName, $c.Name); Favorite = ($favIndex -ge 0); FavoriteIndex = $favIndex }
        }
        $favs = @($items | Where-Object { $_.Favorite } | Sort-Object FavoriteIndex)
        $rest = @($items | Where-Object { -not $_.Favorite } | Sort-Object EnglishName)
        return @($favs + $rest)
    }

    function Get-LPGeoCatalog {
        $seen = @{}
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($c in [Globalization.CultureInfo]::GetCultures([Globalization.CultureTypes]::SpecificCultures)) {
            try { $r = New-Object Globalization.RegionInfo($c.Name) } catch { continue }
            $id = 0
            try { $id = [int]$r.GeoId } catch { continue }
            if ($id -le 0 -or $seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
            $list.Add([pscustomobject]@{ GeoId = $id; Name = $r.EnglishName; Iso2 = $r.TwoLetterISORegionName; Display = ('{0}  ({1}, GeoId {2})' -f $r.EnglishName, $r.TwoLetterISORegionName, $id) })
        }
        return @($list | Sort-Object Name)
    }

    function Get-LPDefaultGeoId {
        param([string]$Format)
        try { return [int](New-Object Globalization.RegionInfo($Format)).GeoId } catch { return 0 }
    }

    function Get-LPGeoName {
        param([int]$GeoId)
        foreach ($g in (Get-LPGeoCatalog)) { if ($g.GeoId -eq $GeoId) { return $g.Name } }
        return "GeoId $GeoId"
    }

    function Get-LPKeyboardLayouts {
        $hklm = Get-LPBaseKey 'LocalMachine'
        $list = New-Object System.Collections.Generic.List[object]
        $root = $hklm.OpenSubKey('SYSTEM\CurrentControlSet\Control\Keyboard Layouts', $false)
        if (-not $root) { return @() }
        try {
            foreach ($id in $root.GetSubKeyNames()) {
                if ($id -notmatch '^[0-9A-Fa-f]{8}$') { continue }
                $k = $root.OpenSubKey($id, $false)
                if (-not $k) { continue }
                try {
                    $text = [string]$k.GetValue('Layout Text', '')
                    $file = [string]$k.GetValue('Layout File', '')
                    $fileOk = $true
                    if ($file) { $fileOk = Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\$file") }
                    if (-not $text) { $text = "Layout $id" }
                    $list.Add([pscustomobject]@{ Id = $id.ToUpperInvariant(); Name = $text; File = $file; FileExists = $fileOk; Display = ('{0}  ({1})' -f $text, $id.ToUpperInvariant()) })
                }
                finally { $k.Close() }
            }
        }
        finally { $root.Close() }
        return @($list | Sort-Object Name)
    }

    function Get-LPLayoutName {
        param([string]$LayoutId, $Layouts)
        foreach ($l in @($Layouts)) { if ($l.Id -eq $LayoutId) { return $l.Name } }
        if ($LayoutId -like '{*') { return 'input method (IME/TSF)' }
        return "layout $LayoutId"
    }

    function Get-LPTipDisplay {
        param([string]$Tip, $Layouts)
        $p = ConvertFrom-LPTip $Tip
        if (-not $p) { return $Tip }
        $langName = ''
        try {
            $lcid = [Convert]::ToInt32($p.Lang, 16)
            $langName = ([Globalization.CultureInfo]::GetCultureInfo($lcid)).Name
        }
        catch { $langName = $p.Lang }
        return ('{0} on {1} [{2}]' -f (Get-LPLayoutName $p.Layout $Layouts), $langName, $p.Tip)
    }

    # --------------------------------------------------------------------------------------------
    # Presets
    # --------------------------------------------------------------------------------------------
    function Get-LPPresets {
        param([string]$Path)
        if (-not $Path) { $Path = Join-Path $script:ScriptRoot 'presets.json' }
        $result = New-Object System.Collections.Generic.List[object]
        $warnings = New-Object System.Collections.Generic.List[string]
        if (Test-Path -LiteralPath $Path) {
            try {
                $data = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
                $raw = @()
                if ($data.PSObject.Properties['presets']) { $raw = @($data.presets) } else { $raw = @($data) }
                foreach ($p in $raw) {
                    $err = Test-LPPresetObject $p
                    if ($err) { $warnings.Add("presets.json: preset '$($p.name)' skipped: $err"); continue }
                    $kb = @($p.keyboards | ForEach-Object { ConvertTo-LPLayoutId ([string]$_) })
                    $geo = 0
                    if ($p.PSObject.Properties['geoId'] -and $p.geoId) { $geo = [int]$p.geoId }
                    $desc = ''
                    if ($p.PSObject.Properties['description'] -and $p.description) { $desc = [string]$p.description }
                    $sysLoc = $null
                    if ($p.PSObject.Properties['systemLocale'] -and $p.systemLocale) { $sysLoc = [string]$p.systemLocale }
                    $result.Add([pscustomobject]@{ name = [string]$p.name; description = $desc; displayLanguage = [string]$p.displayLanguage; regionalFormat = [string]$p.regionalFormat; geoId = $geo; keyboards = $kb; systemLocale = $sysLoc })
                }
            }
            catch { $warnings.Add("presets.json could not be read: $($_.Exception.Message)") }
        }
        else { $warnings.Add("presets.json not found next to the script ($Path); using the built-in Standard preset.") }
        $hasStandard = $false
        foreach ($p in $result) { if ($p.name -eq 'Standard') { $hasStandard = $true } }
        if (-not $hasStandard) { $result.Insert(0, $script:BuiltInStandardPreset) }
        foreach ($w in $warnings) { Write-LPLog $w -Level Warn }
        return [pscustomobject]@{ Presets = $result.ToArray(); Warnings = $warnings.ToArray(); Path = $Path }
    }

    function Test-LPPresetObject {
        param($p)
        if (-not $p) { return 'empty entry' }
        foreach ($f in 'name', 'displayLanguage', 'regionalFormat', 'keyboards') {
            if (-not $p.PSObject.Properties[$f] -or -not $p.$f) { return "missing '$f'" }
        }
        $kbs = @($p.keyboards)
        if ($kbs.Count -eq 0) { return "'keyboards' is empty" }
        foreach ($k in $kbs) { if (-not (ConvertTo-LPLayoutId ([string]$k))) { return "keyboard '$k' is not an 8-digit hex layout ID" } }
        if ($p.PSObject.Properties['geoId'] -and $p.geoId) {
            $g = 0
            if (-not [int]::TryParse([string]$p.geoId, [ref]$g)) { return "geoId '$($p.geoId)' is not a number" }
        }
        return $null
    }

    function Find-LPPreset {
        param($Presets, [string]$Name)
        foreach ($p in @($Presets)) { if ($p.name -eq $Name) { return $p } }
        return $null
    }

    # --------------------------------------------------------------------------------------------
    # Selection (what the admin picked)
    # --------------------------------------------------------------------------------------------
    function New-LPSelection {
        param(
            [string]$PresetName,
            [string]$DisplayLanguage,
            [string]$RegionalFormat,
            [int]$GeoId = 0,
            [string[]]$Keyboards,
            [string[]]$TargetIds,
            [bool]$DisableSync = $true,
            [bool]$BlockRemoteKeyboard = $true,
            [bool]$SetSystemLocale = $false,
            [string]$SystemLocale,
            [bool]$UninstallOthers = $false,
            [string]$LanguageSource
        )
        $disp = $DisplayLanguage
        if ($disp) { $disp = $disp.Trim() }
        $c = Get-LPCultureInfo $disp
        if ($c -and $c.Name) { $disp = $c.Name }
        $fmt = $RegionalFormat
        if ($fmt) { $fmt = $fmt.Trim() }
        $fc = Get-LPCultureInfo $fmt
        if ($fc -and $fc.Name) { $fmt = $fc.Name }
        $kbs = New-Object System.Collections.Generic.List[string]
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($k in @($Keyboards)) {
            if ([string]::IsNullOrWhiteSpace([string]$k)) { continue }
            $id = ConvertTo-LPLayoutId ([string]$k)
            if ($id) { if (-not $kbs.Contains($id)) { $kbs.Add($id) } } else { $bad.Add(([string]$k).Trim()) }
        }
        $lcid = Get-LPLcid $disp
        $tips = New-Object System.Collections.Generic.List[string]
        if ($lcid -gt 0 -and $lcid -ne 4096) { foreach ($k in $kbs) { $tips.Add((ConvertTo-LPTip -Lcid $lcid -LayoutId $k)) } }
        $geo = $GeoId
        if ($geo -le 0 -and $fmt) { $geo = Get-LPDefaultGeoId $fmt }
        $sysLoc = $SystemLocale
        if (-not $sysLoc) { $sysLoc = $fmt }
        $targets = @($TargetIds | Where-Object { $_ } | Select-Object -Unique)
        return [pscustomobject]@{
            PresetName          = $PresetName
            DisplayLanguage     = $disp
            DisplayLcid         = $lcid
            RegionalFormat      = $fmt
            GeoId               = $geo
            Keyboards           = $kbs.ToArray()
            InvalidKeyboards    = $bad.ToArray()
            Tips                = $tips.ToArray()
            TargetIds           = $targets
            DisableSync         = $DisableSync
            BlockRemoteKeyboard = $BlockRemoteKeyboard
            SetSystemLocale     = $SetSystemLocale
            SystemLocale        = $sysLoc
            UninstallOthers     = $UninstallOthers
            LanguageSource      = $LanguageSource
        }
    }

    # --------------------------------------------------------------------------------------------
    # Registry primitives (.NET API only: no PowerShell registry provider, so New-Item -Force can
    # never wipe a key, and handles are closed deterministically before a hive is unloaded)
    # --------------------------------------------------------------------------------------------
    function Get-LPBaseKey {
        param([ValidateSet('Users', 'LocalMachine')][string]$Hive)
        return [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]$Hive, [Microsoft.Win32.RegistryView]::Registry64)
    }

    function Test-LPRegKey {
        param($Base, [string]$Path)
        $k = $null
        try { $k = $Base.OpenSubKey($Path, $false) } catch { return $false }
        if ($k) { $k.Close(); return $true }
        return $false
    }

    function Get-LPRegValue {
        param($Base, [string]$Path, [string]$Name, $Default = $null)
        $k = $null
        try { $k = $Base.OpenSubKey($Path, $false) } catch { return $Default }
        if (-not $k) { return $Default }
        try { return $k.GetValue($Name, $Default, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
        finally { $k.Close() }
    }

    function Get-LPRegValueNames {
        param($Base, [string]$Path)
        $k = $null
        try { $k = $Base.OpenSubKey($Path, $false) } catch { return @() }
        if (-not $k) { return @() }
        try { return @($k.GetValueNames()) } finally { $k.Close() }
    }

    function Get-LPRegSubKeyNames {
        param($Base, [string]$Path)
        $k = $null
        try { $k = $Base.OpenSubKey($Path, $false) } catch { return @() }
        if (-not $k) { return @() }
        try { return @($k.GetSubKeyNames()) } finally { $k.Close() }
    }

    function Read-LPRegTree {
        param([Parameter(Mandatory)]$Key, [switch]$Recurse)
        $vals = New-Object System.Collections.Generic.List[object]
        foreach ($n in $Key.GetValueNames()) {
            $kind = $Key.GetValueKind($n)
            $data = $Key.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            switch ([string]$kind) {
                'Binary' { if ($null -ne $data) { $data = [Convert]::ToBase64String([byte[]]$data) } else { $data = '' } }
                'MultiString' { if ($null -ne $data) { $data = [string[]]$data } else { $data = [string[]]@() } }
                'DWord' { $data = [int]$data }
                'QWord' { $data = [long]$data }
                'String' { $data = [string]$data }
                'ExpandString' { $data = [string]$data }
                default { if ($data -is [byte[]]) { $data = [Convert]::ToBase64String($data) } else { $data = [string]$data } }
            }
            $vals.Add([pscustomobject]@{ Name = $n; Kind = [string]$kind; Data = $data; Present = $true })
        }
        $subs = New-Object System.Collections.Generic.List[object]
        if ($Recurse) {
            foreach ($s in $Key.GetSubKeyNames()) {
                $sk = $Key.OpenSubKey($s, $false)
                if (-not $sk) { continue }
                try {
                    $t = Read-LPRegTree -Key $sk -Recurse
                    $subs.Add([pscustomobject]@{ Name = $s; Values = $t.Values; SubKeys = $t.SubKeys })
                }
                finally { $sk.Close() }
            }
        }
        return [pscustomobject]@{ Values = $vals.ToArray(); SubKeys = $subs.ToArray() }
    }

    function Write-LPRegValues {
        param([Parameter(Mandatory)]$Key, $Values)
        foreach ($v in @($Values)) {
            if ($null -eq $v -or -not $v.Present) { continue }
            $kindName = [string]$v.Kind
            switch ($kindName) {
                'Binary' { $d = [Convert]::FromBase64String([string]$v.Data) }
                'MultiString' { $d = [string[]]@(@($v.Data) | Where-Object { $null -ne $_ }) }
                'DWord' { $d = [int]$v.Data }
                'QWord' { $d = [long]$v.Data }
                'String' { $d = [string]$v.Data }
                'ExpandString' { $d = [string]$v.Data }
                default { Write-LPLog "Skipping value '$($v.Name)' of unsupported type $kindName" -Level Warn; continue }
            }
            $Key.SetValue([string]$v.Name, $d, [Microsoft.Win32.RegistryValueKind]$kindName)
        }
    }

    function Write-LPRegTree {
        param([Parameter(Mandatory)]$Key, $Tree)
        Write-LPRegValues -Key $Key -Values $Tree.Values
        foreach ($s in @($Tree.SubKeys)) {
            if ($null -eq $s) { continue }
            $sk = $Key.CreateSubKey([string]$s.Name)
            try { Write-LPRegTree -Key $sk -Tree $s } finally { $sk.Close() }
        }
    }

    function Remove-LPRegTree {
        param($Base, [string]$Path)
        if (Test-LPRegKey $Base $Path) { $Base.DeleteSubKeyTree($Path, $false) }
    }

    # Snapshot of one key-set entry, relative to a hive root (JSON-serializable).
    function Get-LPKeySnapshot {
        param([Parameter(Mandatory)]$Base, [Parameter(Mandatory)][AllowEmptyString()][string]$Root, [Parameter(Mandatory)]$Spec)
        $path = Join-LPRegPath $Root $Spec.Path
        $snap = [pscustomobject]@{ Id = $Spec.Id; Path = $Spec.Path; Mode = $Spec.Mode; Names = $Spec.Names; Exists = $false; MissingFrom = $null; Values = @(); SubKeys = @() }
        $k = $null
        try { $k = $Base.OpenSubKey($path, $false) } catch { throw "Cannot read $path : $($_.Exception.Message)" }
        if (-not $k) {
            # Topmost key of the path that did not exist, so Restore can remove keys the tool created.
            $acc = ''
            foreach ($part in $Spec.Path.Split('\')) {
                if ($acc) { $acc = "$acc\$part" } else { $acc = $part }
                if (-not (Test-LPRegKey $Base (Join-LPRegPath $Root $acc))) { $snap.MissingFrom = $acc; break }
            }
            if ($Spec.Mode -eq 'Value') {
                $snap.Values = @(foreach ($n in $Spec.Names) { [pscustomobject]@{ Name = $n; Kind = 'String'; Data = $null; Present = $false } })
            }
            return $snap
        }
        try {
            $snap.Exists = $true
            switch ($Spec.Mode) {
                'Tree' { $t = Read-LPRegTree -Key $k -Recurse; $snap.Values = $t.Values; $snap.SubKeys = $t.SubKeys }
                'Values' { $t = Read-LPRegTree -Key $k; $snap.Values = $t.Values }
                'Value' {
                    $all = (Read-LPRegTree -Key $k).Values
                    $snap.Values = @(foreach ($n in $Spec.Names) {
                            $m = $null
                            foreach ($a in $all) { if ($a.Name -eq $n) { $m = $a; break } }
                            if ($m) { $m } else { [pscustomobject]@{ Name = $n; Kind = 'String'; Data = $null; Present = $false } }
                        })
                }
            }
        }
        finally { $k.Close() }
        return $snap
    }

    # Applies a snapshot to a hive root with REPLACE semantics (see $script:LanguageKeySet).
    function Set-LPKeyFromSnapshot {
        param([Parameter(Mandatory)]$Base, [Parameter(Mandatory)][AllowEmptyString()][string]$Root, [Parameter(Mandatory)]$Snapshot)
        $path = Join-LPRegPath $Root $Snapshot.Path
        switch ([string]$Snapshot.Mode) {
            'Tree' {
                Remove-LPRegTree -Base $Base -Path $path
                if ($Snapshot.Exists) {
                    $k = $Base.CreateSubKey($path)
                    try { Write-LPRegTree -Key $k -Tree $Snapshot } finally { $k.Close() }
                }
            }
            'Values' {
                if ($Snapshot.Exists) {
                    $k = $Base.CreateSubKey($path)
                    try {
                        foreach ($n in $k.GetValueNames()) { $k.DeleteValue($n, $false) }
                        Write-LPRegValues -Key $k -Values $Snapshot.Values
                    }
                    finally { $k.Close() }
                }
                elseif (Test-LPRegKey $Base $path) {
                    $k = $Base.OpenSubKey($path, $true)
                    try { foreach ($n in $k.GetValueNames()) { $k.DeleteValue($n, $false) } } finally { $k.Close() }
                }
            }
            'Value' {
                foreach ($v in @($Snapshot.Values)) {
                    if ($null -eq $v) { continue }
                    if ($v.Present) {
                        $k = $Base.CreateSubKey($path)
                        try { Write-LPRegValues -Key $k -Values @($v) } finally { $k.Close() }
                    }
                    elseif (Test-LPRegKey $Base $path) {
                        $k = $Base.OpenSubKey($path, $true)
                        try { $k.DeleteValue([string]$v.Name, $false) } finally { $k.Close() }
                    }
                }
            }
            default { throw "Unknown snapshot mode '$($Snapshot.Mode)'" }
        }
        if (-not $Snapshot.Exists -and $Snapshot.PSObject.Properties['MissingFrom'] -and $Snapshot.MissingFrom) {
            Remove-LPEmptyKeyChain -Base $Base -Root $Root -Path ([string]$Snapshot.Path) -Top ([string]$Snapshot.MissingFrom)
        }
    }

    # Deletes $Path and its parents up to $Top (relative to $Root) as long as they are empty.
    function Remove-LPEmptyKeyChain {
        param([Parameter(Mandatory)]$Base, [AllowEmptyString()][string]$Root, [string]$Path, [string]$Top)
        $rel = $Path
        while ($rel) {
            $full = Join-LPRegPath $Root $rel
            $k = $null
            try { $k = $Base.OpenSubKey($full, $false) } catch { }
            if ($k) {
                $empty = (@($k.GetValueNames()).Count -eq 0 -and @($k.GetSubKeyNames()).Count -eq 0)
                $k.Close()
                if (-not $empty) { break }
                $Base.DeleteSubKeyTree($full, $false)
            }
            if ($rel -eq $Top) { break }
            $i = $rel.LastIndexOf('\')
            if ($i -lt 0) { break }
            $rel = $rel.Substring(0, $i)
        }
    }

    function Join-LPRegPath {
        param([AllowEmptyString()][string]$Root, [string]$Path)
        if ([string]::IsNullOrEmpty($Root)) { return $Path }
        return ($Root.TrimEnd('\') + '\' + $Path)
    }

    function Set-LPRegDword {
        param($Base, [string]$Path, [string]$Name, [int]$Value)
        $k = $Base.CreateSubKey($Path)
        try { $k.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::DWord) } finally { $k.Close() }
    }

    # --------------------------------------------------------------------------------------------
    # Hive mounting (offline profiles and the Default profile)
    # --------------------------------------------------------------------------------------------
    function Get-LPLoadedHives {
        $hku = Get-LPBaseKey 'Users'
        return @($hku.GetSubKeyNames())
    }

    # Returns @{ Root; MountedByUs; HivePath } or throws. If the hive of $Sid is already loaded
    # (signed-in user, the elevated admin, a service account) it is used in place.
    function Mount-LPHive {
        param([string]$Sid, [string]$HivePath, [Parameter(Mandatory)][string]$Label)
        $hku = Get-LPBaseKey 'Users'
        if ($Sid -and (Test-LPRegKey $hku $Sid)) {
            return [pscustomobject]@{ Root = $Sid; MountedByUs = $false; HivePath = $HivePath }
        }
        if (-not $HivePath) { throw "No hive file known for $Label." }
        if (-not (Test-Path -LiteralPath $HivePath)) { throw "Hive file not found: $HivePath" }
        $name = $script:HiveMountPrefix + ($Label -replace '[^A-Za-z0-9_-]', '_')
        if (Test-LPRegKey $hku $name) {
            Write-LPLog "Unloading a stale mount HKU\$name from an earlier run." -Level Warn
            Dismount-LPHive ([pscustomobject]@{ Root = $name; MountedByUs = $true; HivePath = $null })
        }
        $r = Invoke-LPReg @('load', "HKU\$name", $HivePath)
        if ($r.ExitCode -ne 0) { throw "Could not load $HivePath (locked by another process, or damaged): $($r.Output)" }
        Write-LPLog "Loaded $HivePath as HKU\$name" -Level Detail
        return [pscustomobject]@{ Root = $name; MountedByUs = $true; HivePath = $HivePath }
    }

    function Dismount-LPHive {
        param($Mount)
        if (-not $Mount -or -not $Mount.MountedByUs) { return }
        for ($i = 1; $i -le 6; $i++) {
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
            [gc]::Collect()
            $r = Invoke-LPReg @('unload', "HKU\$($Mount.Root)")
            if ($r.ExitCode -eq 0) { Write-LPLog "Unloaded HKU\$($Mount.Root)" -Level Detail; return }
            Start-Sleep -Milliseconds (400 * $i)
        }
        Write-LPLog "Could not unload HKU\$($Mount.Root). It will be unloaded at the next start of the tool or at restart." -Level Error
    }

    # Mounts (if needed), runs $Action with (hkuBaseKey, root) and always unmounts in finally.
    function Use-LPHive {
        param([string]$Sid, [string]$HivePath, [Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][scriptblock]$Action)
        $mount = Mount-LPHive -Sid $Sid -HivePath $HivePath -Label $Label
        try {
            $hku = Get-LPBaseKey 'Users'
            return (& $Action $hku $mount.Root)
        }
        finally { Dismount-LPHive $mount }
    }

    function Clear-LPStaleState {
        # Leftovers of a crashed run: temporary hive mounts, one-time tasks, job folders.
        foreach ($n in (Get-LPLoadedHives)) {
            if ($n -like "$($script:HiveMountPrefix)*") {
                Write-LPLog "Unloading stale hive mount HKU\$n" -Level Warn
                Dismount-LPHive ([pscustomobject]@{ Root = $n; MountedByUs = $true })
            }
        }
        try {
            $tasks = @(Get-ScheduledTask -TaskPath $script:TaskPath -ErrorAction SilentlyContinue)
            foreach ($t in $tasks) {
                if (-not $t) { continue }
                Write-LPLog "Removing stale task $($t.TaskPath)$($t.TaskName)" -Level Warn
                Unregister-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
        catch { }
        $jobs = Join-Path $script:DataRoot 'Jobs'
        if (Test-Path -LiteralPath $jobs) {
            Get-ChildItem -LiteralPath $jobs -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch { }
            }
        }
    }

    # --------------------------------------------------------------------------------------------
    # Language lists and text-services entries
    # --------------------------------------------------------------------------------------------
    # Reads a language list key ("User Profile" or "User Profile System Backup").
    function Read-LPLanguageList {
        param([Parameter(Mandatory)]$Base, [Parameter(Mandatory)][string]$Path)
        $langs = @()
        $v = Get-LPRegValue $Base $Path 'Languages'
        if ($null -ne $v) { $langs = @($v | Where-Object { $_ }) }
        $langTips = [ordered]@{}
        $langIds = @{}
        $allTips = New-Object System.Collections.Generic.List[string]
        foreach ($l in $langs) {
            $lk = $null
            try { $lk = $Base.OpenSubKey((Join-LPRegPath $Path $l), $false) } catch { }
            $pairs = @()
            $transient = $null
            if ($lk) {
                try {
                    $pairs = @(foreach ($n in $lk.GetValueNames()) {
                            if ($n -match '^[0-9A-Fa-f]{4}:') {
                                $order = 0
                                try { $order = [int]$lk.GetValue($n) } catch { }
                                [pscustomobject]@{ Tip = (ConvertFrom-LPTip $n).Tip; Order = $order }
                            }
                        })
                    $tl = $lk.GetValue('TransientLangId')
                    if ($null -ne $tl) { $transient = [int]$tl }
                }
                finally { $lk.Close() }
            }
            $tips = @($pairs | Sort-Object Order | ForEach-Object { $_.Tip })
            $langTips[$l] = $tips
            foreach ($t in $tips) { if (-not $allTips.Contains($t)) { $allTips.Add($t) } }
            # Language ID used by keyboard layouts and text services: transient ID (0x2000...) for languages without LCID.
            if ($null -ne $transient) { $langIds[$l] = $transient } else { $id = Get-LPLcid $l; if ($id -gt 0 -and $id -ne 4096) { $langIds[$l] = $id } }
        }
        return [pscustomobject]@{ Exists = (Test-LPRegKey $Base $Path); Languages = $langs; LanguageTips = $langTips; Tips = $allTips.ToArray(); LangIds = $langIds }
    }

    function ConvertFrom-LPLangIdName {
        param([string]$Name)
        if ($null -eq $Name) { return $null }
        $t = $Name.Trim()
        if ($t -match '^0x([0-9A-Fa-f]{1,8})$') { return [Convert]::ToInt32($Matches[1], 16) }
        if ($t -match '^[0-9A-Fa-f]{8}$') { return [Convert]::ToInt32($t, 16) }
        return $null
    }

    # Language IDs that Text Services Framework still has entries for (CTF\SortOrder\AssemblyItem, CTF\Assemblies).
    function Get-LPCtfLangIds {
        param([Parameter(Mandatory)]$Base, [AllowEmptyString()][string]$Root)
        $ids = New-Object System.Collections.Generic.List[int]
        foreach ($rel in 'Software\Microsoft\CTF\SortOrder\AssemblyItem', 'Software\Microsoft\CTF\Assemblies') {
            foreach ($n in (Get-LPRegSubKeyNames $Base (Join-LPRegPath $Root $rel))) {
                $id = ConvertFrom-LPLangIdName $n
                if ($null -ne $id -and -not $ids.Contains($id)) { $ids.Add($id) }
            }
        }
        $lp = Join-LPRegPath $Root 'Software\Microsoft\CTF\SortOrder\Language'
        foreach ($n in (Get-LPRegValueNames $Base $lp)) {
            $id = ConvertFrom-LPLangIdName ([string](Get-LPRegValue $Base $lp $n))
            if ($null -ne $id -and -not $ids.Contains($id)) { $ids.Add($id) }
        }
        return $ids.ToArray()
    }

    function Get-LPLangIdDisplay {
        param([int]$LangId)
        $name = $null
        if ($LangId -ge 0x2000 -and $LangId -le 0x2C00 -and ($LangId % 0x400) -eq 0) { return ('0x{0:X4} (language without its own ID)' -f $LangId) }
        try { $name = ([Globalization.CultureInfo]::GetCultureInfo($LangId)).Name } catch { }
        if ($name) { return ('{0} (0x{1:X4})' -f $name, $LangId) }
        return ('0x{0:X4}' -f $LangId)
    }

    # --------------------------------------------------------------------------------------------
    # Reading the language state of one hive (signed-in user, offline profile, .DEFAULT, Default)
    # --------------------------------------------------------------------------------------------
    function Get-LPHiveState {
        param([Parameter(Mandatory)]$Base, [Parameter(Mandatory)][AllowEmptyString()][string]$Root, $Layouts)
        $up = Join-LPRegPath $Root 'Control Panel\International\User Profile'
        $list = Read-LPLanguageList -Base $Base -Path $up
        $backup = Read-LPLanguageList -Base $Base -Path (Join-LPRegPath $Root 'Control Panel\International\User Profile System Backup')
        $imo = Get-LPRegValue $Base $up 'InputMethodOverride'
        $override = Get-LPRegValue $Base $up 'WindowsOverride'
        $desktop = Join-LPRegPath $Root 'Control Panel\Desktop'
        $preferred = $null
        $v = Get-LPRegValue $Base $desktop 'PreferredUILanguages'
        if ($null -ne $v) { $preferred = @($v | Where-Object { $_ }) | Select-Object -First 1 }
        $uiPending = $null
        $v = Get-LPRegValue $Base $desktop 'PreferredUILanguagesPending'
        if ($null -ne $v) { $uiPending = @($v | Where-Object { $_ }) | Select-Object -First 1 }
        $machineUi = $null
        $v = Get-LPRegValue $Base (Join-LPRegPath $Root 'Control Panel\Desktop\MuiCached') 'MachinePreferredUILanguages'
        if ($null -ne $v) { $machineUi = @($v | Where-Object { $_ }) | Select-Object -First 1 }
        # Effective user display language: the override (Set-WinUILanguageOverride writes
        # User Profile\WindowsOverride), else the pending value (active after sign-in), else the current one.
        $ui = $override
        if (-not $ui) { $ui = $uiPending }
        if (-not $ui) { $ui = $preferred }
        $format = Get-LPRegValue $Base (Join-LPRegPath $Root 'Control Panel\International') 'LocaleName'
        $geo = Get-LPRegValue $Base (Join-LPRegPath $Root 'Control Panel\International\Geo') 'Nation'
        $geoId = 0
        if ($geo) { [void][int]::TryParse([string]$geo, [ref]$geoId) }

        $preloadPath = Join-LPRegPath $Root 'Keyboard Layout\Preload'
        $preloadVals = @()
        $names = @(Get-LPRegValueNames $Base $preloadPath | Where-Object { $_ -match '^\d+$' } | Sort-Object { [int]$_ })
        foreach ($n in $names) { $preloadVals += [string](Get-LPRegValue $Base $preloadPath $n) }
        $subs = @{}
        $subPath = Join-LPRegPath $Root 'Keyboard Layout\Substitutes'
        foreach ($n in (Get-LPRegValueNames $Base $subPath)) { $subs[$n] = [string](Get-LPRegValue $Base $subPath $n) }
        $pp = Get-LPPreloadPlan -DesiredTips $list.Tips -Preload $preloadVals -Substitutes $subs
        $hidden = @($pp.Removed | ForEach-Object { if ($_.Valid) { $_.Tip } else { $_.Value } })

        $listIds = @($list.LangIds.Values)
        $ctfIds = @(Get-LPCtfLangIds -Base $Base -Root $Root)
        $ctfForeign = @($ctfIds | Where-Object { $listIds -notcontains $_ })

        $sync = Get-LPRegValue $Base (Join-LPRegPath $Root $script:SyncKeySpec.Path) 'Enabled'
        return [pscustomobject]@{
            Languages           = $list.Languages
            LanguageTips        = $list.LanguageTips
            Tips                = $list.Tips
            LangIds             = $list.LangIds
            InputMethodOverride = $imo
            UILanguage          = $ui
            UILanguageOverride  = $override
            UILanguageCurrent   = $preferred
            UILanguagePending   = $uiPending
            MachineUILanguage   = $machineUi
            Format              = $format
            GeoId               = $geoId
            Preload             = $preloadVals
            PreloadTips         = @($pp.Entries | ForEach-Object { if ($_.Valid) { $_.Tip } else { $_.Value } })
            Substitutes         = $subs
            Hidden              = $hidden
            BackupExists        = $backup.Exists
            BackupLanguages     = $backup.Languages
            BackupTips          = $backup.Tips
            CtfLangIds          = $ctfIds
            CtfForeignLangIds   = $ctfForeign
            SyncEnabled         = $sync
        }
    }

    # Windows keeps a copy of the language list in "User Profile System Backup" and restores it in
    # some situations. Set-WinUserLanguageList does not update it (registry diff on Windows 11 25H2:
    # the backup still contained the US keyboard afterwards). Make it an exact copy of "User Profile",
    # without the override values (Windows' own backups don't contain them).
    function Sync-LPLanguageBackup {
        param([Parameter(Mandatory)]$Base, [AllowEmptyString()][string]$Root = '')
        $src = Join-LPRegPath $Root 'Control Panel\International\User Profile'
        $dst = Join-LPRegPath $Root 'Control Panel\International\User Profile System Backup'
        $k = $Base.OpenSubKey($src, $false)
        if (-not $k) { return $false }
        try { $tree = Read-LPRegTree -Key $k -Recurse } finally { $k.Close() }
        $vals = @($tree.Values | Where-Object { $_.Name -ne 'InputMethodOverride' -and $_.Name -ne 'WindowsOverride' })
        Remove-LPRegTree -Base $Base -Path $dst
        $d = $Base.CreateSubKey($dst)
        try { Write-LPRegTree -Key $d -Tree ([pscustomobject]@{ Values = $vals; SubKeys = $tree.SubKeys }) } finally { $d.Close() }
        return $true
    }

    # Text Services Framework keeps per-language entries in CTF\SortOrder and CTF\Assemblies. Windows
    # leaves entries of removed languages behind (registry diff: en-GB with a German keyboard), and
    # Microsoft's own "copy to welcome screen" carries them along. Remove every language except $LangIds.
    function Clear-LPCtfLeftovers {
        param([Parameter(Mandatory)]$Base, [AllowEmptyString()][string]$Root = '', [Parameter(Mandatory)][int[]]$LangIds)
        $removed = New-Object System.Collections.Generic.List[string]
        foreach ($rel in 'Software\Microsoft\CTF\SortOrder\AssemblyItem', 'Software\Microsoft\CTF\Assemblies') {
            $p = Join-LPRegPath $Root $rel
            foreach ($n in @(Get-LPRegSubKeyNames $Base $p)) {
                $id = ConvertFrom-LPLangIdName $n
                if ($null -ne $id -and -not ($LangIds -contains $id)) {
                    $Base.DeleteSubKeyTree((Join-LPRegPath $p $n), $false)
                    $removed.Add("$rel\$n")
                }
            }
        }
        $lp = Join-LPRegPath $Root 'Software\Microsoft\CTF\SortOrder\Language'
        if (Test-LPRegKey $Base $lp) {
            $k = $Base.OpenSubKey($lp, $true)
            try {
                $names = @($k.GetValueNames() | Sort-Object)
                $keep = New-Object System.Collections.Generic.List[string]
                $changed = $false
                foreach ($n in $names) {
                    $v = [string]$k.GetValue($n)
                    $id = ConvertFrom-LPLangIdName $v
                    if ($null -ne $id -and ($LangIds -contains $id) -and -not $keep.Contains($v)) { $keep.Add($v) }
                    else { $changed = $true; $removed.Add("SortOrder\Language\$n = $v") }
                }
                if ($changed) {
                    foreach ($n in $names) { $k.DeleteValue($n, $false) }
                    $i = 0
                    foreach ($v in $keep) { $k.SetValue(('{0:D8}' -f $i), $v, [Microsoft.Win32.RegistryValueKind]::String); $i++ }
                }
            }
            finally { $k.Close() }
        }
        return $removed.ToArray()
    }

    # --------------------------------------------------------------------------------------------
    # Language policies (GPO / Intune). Detected and reported, never changed.
    # --------------------------------------------------------------------------------------------
    function Get-LPPolicyValues {
        param([Parameter(Mandatory)]$Base, [AllowEmptyString()][string]$Root, [ValidateSet('Machine', 'User')][string]$Scope, [string]$Label)
        $out = New-Object System.Collections.Generic.List[object]
        if ($Scope -eq 'Machine') {
            $sources = @(
                @{ Path = 'SOFTWARE\Policies\Microsoft\Control Panel\International'; Names = $null; Source = 'Group Policy / Intune'; Hive = 'HKLM' }
                @{ Path = 'SOFTWARE\Policies\Microsoft\MUI\Settings'; Names = $null; Source = 'Group Policy / Intune'; Hive = 'HKLM' }
                @{ Path = 'SOFTWARE\Microsoft\PolicyManager\current\device\TimeLanguageSettings'; Names = @('RestrictLanguagePacksAndFeaturesInstall', 'BlockCleanupOfUnusedPreinstalledLangPacks', 'MachineUILanguageOverwrite'); Source = 'Intune (MDM policy)'; Hive = 'HKLM' }
            )
        }
        else {
            $sources = @(
                @{ Path = (Join-LPRegPath $Root 'Software\Policies\Microsoft\Control Panel\International'); Names = $null; Source = 'Group Policy / Intune'; Hive = 'HKU' }
                @{ Path = (Join-LPRegPath $Root 'Software\Policies\Microsoft\Control Panel\Desktop'); Names = @('PreferredUILanguages', 'MultiUILanguageID'); Source = 'Group Policy / Intune'; Hive = 'HKU' }
            )
        }
        foreach ($s in $sources) {
            $names = @(Get-LPRegValueNames $Base $s.Path)
            foreach ($n in $names) {
                if (-not $n -or $n.StartsWith('_') -or $n -match '_(ProviderSet|WinningProvider|LastWrite|ADMXInstanceData)$') { continue }
                if ($s.Names -and -not ($s.Names -contains $n)) { continue }
                $val = Get-LPRegValue $Base $s.Path $n
                if ($val -is [array]) { $val = ($val -join ';') }
                $out.Add([pscustomobject]@{ Scope = $Scope; Label = $Label; Key = ('{0}\{1}' -f $s.Hive, $s.Path); Name = $n; Value = [string]$val; Source = $s.Source })
            }
        }
        return $out.ToArray()
    }

    # Classifies one policy value against the selection.
    #   returns @{ State = Blocked|Warn|Info; Blocks = 'ui'|'format'|'geo'|'pack'|$null; Text; Detail }
    function Get-LPPolicyEffect {
        param([Parameter(Mandatory)]$Policy, [Parameter(Mandatory)]$Selection)
        $cat = $script:PolicyCatalog[$Policy.Name]
        $where = '{0}\{1} = {2}' -f $Policy.Key, $Policy.Name, $Policy.Value
        $setting = $null
        if ($cat) { $setting = $cat.Setting }
        $state = 'Warn'; $blocks = $null; $text = "Language policy present: $($Policy.Name)"
        if (-not $cat) {
            $text = "Unknown language policy '$($Policy.Name)' - it may override the result"
        }
        else {
            switch ($cat.Effect) {
                'BlockPack' {
                    if ([string]$Policy.Value -eq '1') { $state = 'Blocked'; $blocks = 'pack'; $text = 'A policy blocks installing and removing language packs' }
                    else { $state = 'Info'; $text = "$($Policy.Name) is set to $($Policy.Value) (no effect)" }
                }
                'BlockUi' {
                    $v = ([string]$Policy.Value).Split(';')[0]
                    if ($Policy.Name -eq 'PreferredUILanguages' -and $v -and $v -eq $Selection.DisplayLanguage) { $state = 'Info'; $text = "A policy already forces the display language $v (same as selected)" }
                    else { $state = 'Blocked'; $blocks = 'ui'; $text = "A policy forces the display language ($($Policy.Name) = $($Policy.Value))" }
                }
                'BlockFormat' {
                    $list = @(([string]$Policy.Value).Split(';', ',', ' ') | Where-Object { $_ })
                    $allowed = $false
                    foreach ($x in $list) { if ($x -eq $Selection.RegionalFormat) { $allowed = $true } }
                    if ($allowed) { $state = 'Info'; $text = "A policy restricts regional formats; $($Selection.RegionalFormat) is allowed" }
                    else { $state = 'Blocked'; $blocks = 'format'; $text = "A policy restricts regional formats and $($Selection.RegionalFormat) is not in the allowed list ($($Policy.Value))" }
                }
                'BlockGeo' {
                    if ([string]$Policy.Value -eq '1') { $state = 'Blocked'; $blocks = 'geo'; $text = 'A policy prevents changing the country/region' }
                    else { $state = 'Info'; $text = "$($Policy.Name) is set to $($Policy.Value) (no effect)" }
                }
                'Info' { $state = 'Info'; $text = "Language policy present: $($Policy.Name) = $($Policy.Value) (does not change the result)" }
                default { $state = 'Warn'; $text = "Language policy present: $($Policy.Name) = $($Policy.Value) - may override the result" }
            }
        }
        $detail = @("Set at: $where (source: $($Policy.Source))")
        if ($setting) { $detail += "Policy setting: $setting" }
        if ($state -eq 'Blocked' -or $state -eq 'Warn') {
            $detail += 'This tool does not fight policies. Whoever manages the policy has to change or remove it: run "gpresult /h report.html" to find the GPO; if no GPO sets it, check the Intune configuration profiles assigned to this device/user. Then run the tool again.'
        }
        return [pscustomobject]@{ State = $state; Blocks = $blocks; Text = $text; Detail = $detail }
    }

    # --------------------------------------------------------------------------------------------
    # Sessions, profiles
    # --------------------------------------------------------------------------------------------
    function Get-LPSignedInUsers {
        # Owner of explorer.exe per session = interactively signed-in user.
        $map = @{}
        try {
            foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)) {
                try {
                    $o = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop
                    if (-not $o.Sid) { continue }
                    if (-not $map.ContainsKey($o.Sid)) {
                        $owner = $null
                        try { $ow = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop; if ($ow.User) { $owner = '{0}\{1}' -f $ow.Domain, $ow.User } } catch { }
                        $map[$o.Sid] = [pscustomobject]@{ Sid = $o.Sid; Account = $owner; SessionIds = @() }
                    }
                    $map[$o.Sid].SessionIds = @($map[$o.Sid].SessionIds) + @([int]$p.SessionId)
                }
                catch { }
            }
        }
        catch { Write-LPLog "Could not list explorer.exe processes: $($_.Exception.Message)" -Level Warn }
        return $map
    }

    function Resolve-LPSidName {
        param([string]$Sid, [string]$FallbackPath)
        try { return (New-Object Security.Principal.SecurityIdentifier($Sid)).Translate([Security.Principal.NTAccount]).Value } catch { }
        if ($FallbackPath) { return ('{0} (account not resolvable)' -f (Split-Path -Path $FallbackPath -Leaf)) }
        return $Sid
    }

    function Get-LPProfiles {
        $hklm = Get-LPBaseKey 'LocalMachine'
        $pl = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($sid in (Get-LPRegSubKeyNames $hklm $pl)) {
            if ($sid -notmatch '^S-1-(5-21|12-1)-\d+(-\d+)+$') { continue }   # real local/domain/Entra accounts only; also skips *.bak
            $rid = [long]($sid.Split('-')[-1])
            if ($rid -in 501, 503, 504) { continue }                            # Guest, DefaultAccount, WDAGUtilityAccount
            $raw = [string](Get-LPRegValue $hklm "$pl\$sid" 'ProfileImagePath')
            if (-not $raw) { continue }
            $path = [Environment]::ExpandEnvironmentVariables($raw)
            $leaf = Split-Path -Path $path -Leaf
            if ($leaf -match '^defaultuser\d+') { continue }                   # OOBE leftovers
            $hive = Join-Path $path 'NTUSER.DAT'
            $list.Add([pscustomobject]@{ Sid = $sid; ProfilePath = $path; HivePath = $hive; HiveExists = (Test-Path -LiteralPath $hive); Name = (Resolve-LPSidName -Sid $sid -FallbackPath $path) })
        }
        return $list.ToArray()
    }

    function Get-LPDefaultProfileHive {
        $hklm = Get-LPBaseKey 'LocalMachine'
        $pl = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        $raw = [string](Get-LPRegValue $hklm $pl 'Default')
        if (-not $raw) {
            $dir = [string](Get-LPRegValue $hklm $pl 'ProfilesDirectory')
            if ($dir) { $raw = Join-Path $dir 'Default' }
        }
        if (-not $raw) { $raw = Join-Path $env:SystemDrive 'Users\Default' }
        return (Join-Path ([Environment]::ExpandEnvironmentVariables($raw)) 'NTUSER.DAT')
    }

    function Get-LPPendingReboot {
        $hklm = Get-LPBaseKey 'LocalMachine'
        $reasons = New-Object System.Collections.Generic.List[string]
        if (Test-LPRegKey $hklm 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons.Add('Windows component servicing (e.g. a language pack or update) waits for a restart') }
        if (Test-LPRegKey $hklm 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending') { $reasons.Add('Windows packages are pending installation') }
        if (Test-LPRegKey $hklm 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons.Add('Windows Update waits for a restart') }
        return [pscustomobject]@{ Pending = ($reasons.Count -gt 0); Reasons = $reasons.ToArray() }
    }

    function Test-LPCommand {
        param([string]$Name)
        return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
    }

    # --------------------------------------------------------------------------------------------
    # Scan: everything the readiness check, the preview and the Status tab need (read-only)
    # --------------------------------------------------------------------------------------------
    function Get-LPSnapshot {
        param([switch]$SkipOfflineHives)
        Write-LPLog 'Scanning this PC (read-only)...' -Level Step
        $errors = New-Object System.Collections.Generic.List[string]
        $hklm = Get-LPBaseKey 'LocalMachine'
        $hku = Get-LPBaseKey 'Users'

        # --- Windows ---
        $os = $null
        try {
            $w = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $cv = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion'
            $build = [int]$w.BuildNumber
            $disp = [string](Get-LPRegValue $hklm $cv 'DisplayVersion')
            if (-not $disp) { $disp = [string](Get-LPRegValue $hklm $cv 'ReleaseId') }
            $ubr = Get-LPRegValue $hklm $cv 'UBR'
            $edition = [string](Get-LPRegValue $hklm $cv 'EditionID')
            $isWin11 = $build -ge 22000
            $family = 'Windows 10'
            if ($isWin11) { $family = 'Windows 11' }
            $os = [pscustomobject]@{
                Caption        = [string]$w.Caption
                Name           = ('{0} {1} {2} (build {3}.{4})' -f $family, $edition, $disp, $build, $ubr)
                Build          = $build
                DisplayVersion = $disp
                EditionId      = $edition
                IsWin11        = $isWin11
                SingleLanguage = ($edition -match 'SingleLanguage|CountrySpecific')
                MUILanguages   = @($w.MUILanguages)
            }
        }
        catch { $errors.Add("Windows version: $($_.Exception.Message)") }

        # --- this process ---
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($id)
        $proc = [pscustomobject]@{
            UserName     = $id.Name
            Sid          = $id.User.Value
            IsSystem     = ($id.User.Value -eq 'S-1-5-18')
            IsAdmin      = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            LanguageMode = [string]$ExecutionContext.SessionState.LanguageMode
        }

        # --- capabilities ---
        $caps = [pscustomobject]@{
            InstallLanguage                       = (Test-LPCommand 'Install-Language')
            InstallLanguageExcludeFeatures        = $false
            GetInstalledLanguage                  = (Test-LPCommand 'Get-InstalledLanguage')
            UninstallLanguage                     = (Test-LPCommand 'Uninstall-Language')
            SetSystemPreferredUILanguage          = (Test-LPCommand 'Set-SystemPreferredUILanguage')
            GetSystemPreferredUILanguage          = (Test-LPCommand 'Get-SystemPreferredUILanguage')
            CopyUserInternationalSettingsToSystem = (Test-LPCommand 'Copy-UserInternationalSettingsToSystem')
            AddWindowsPackage                     = (Test-LPCommand 'Add-WindowsPackage')
            TaskScheduler                         = $false
        }
        if ($caps.InstallLanguage) {
            try { $caps.InstallLanguageExcludeFeatures = (Get-Command Install-Language).Parameters.ContainsKey('ExcludeFeatures') } catch { }
        }
        try { $caps.TaskScheduler = ((Get-Service -Name Schedule -ErrorAction Stop).Status -eq 'Running') } catch { }

        # --- installed languages ---
        $installed = New-Object System.Collections.Generic.List[string]
        $full = New-Object System.Collections.Generic.List[string]
        $lxp = New-Object System.Collections.Generic.List[string]
        $details = New-Object System.Collections.Generic.List[object]
        $addTag = { param($list, $tag) if ($tag -and -not ($list -contains $tag)) { $list.Add([string]$tag) } }
        if ($os) { foreach ($m in $os.MUILanguages) { & $addTag $installed $m; & $addTag $full $m } }
        foreach ($m in (Get-LPRegSubKeyNames $hklm 'SYSTEM\CurrentControlSet\Control\MUI\UILanguages')) { & $addTag $installed $m; & $addTag $full $m }
        if ($caps.GetInstalledLanguage) {
            try {
                foreach ($l in @(Get-InstalledLanguage -ErrorAction Stop)) {
                    $tag = $null
                    foreach ($pn in 'LanguageId', 'Language', 'LanguageTag') { if ($l.PSObject.Properties[$pn] -and $l.$pn) { $tag = [string]$l.$pn; break } }
                    if (-not $tag) { continue }
                    $packs = ''
                    if ($l.PSObject.Properties['LanguagePacks']) { $packs = [string]$l.LanguagePacks }
                    $details.Add([pscustomobject]@{ Tag = $tag; Packs = $packs })
                    if ($packs -and $packs -ne 'None') {
                        & $addTag $installed $tag
                        if ($packs -match 'LpCab') { & $addTag $full $tag }
                    }
                }
            }
            catch { $errors.Add("Get-InstalledLanguage: $($_.Exception.Message)") }
        }
        & $addTag $installed ([Globalization.CultureInfo]::CurrentUICulture.Name)
        foreach ($t in $installed) { if (-not ($full -contains $t)) { $lxp.Add($t) } }
        $sysUi = $null
        if ($caps.GetSystemPreferredUILanguage) { try { $sysUi = [string](Get-SystemPreferredUILanguage -ErrorAction Stop) } catch { } }
        if (-not $sysUi) { $sysUi = [Globalization.CultureInfo]::InstalledUICulture.Name }
        $sysLocale = $null
        try { $sysLocale = (Get-WinSystemLocale -ErrorAction Stop).Name } catch { }
        $installLang = $null
        $il = [string](Get-LPRegValue $hklm 'SYSTEM\CurrentControlSet\Control\Nls\Language' 'InstallLanguage')
        if ($il) { try { $installLang = ([Globalization.CultureInfo]::GetCultureInfo([Convert]::ToInt32($il, 16))).Name } catch { } }
        $languages = [pscustomobject]@{
            Installed                 = $installed.ToArray()
            FullPack                  = $full.ToArray()
            LxpOnly                   = $lxp.ToArray()
            Details                   = $details.ToArray()
            SystemPreferredUILanguage = $sysUi
            SystemLocale              = $sysLocale
            InstallLanguage           = $installLang
        }

        # --- machine settings and policies ---
        $machine = [pscustomobject]@{
            IgnoreRemoteKeyboardLayout = (Get-LPRegValue $hklm $script:RemoteKbSpec.Path 'IgnoreRemoteKeyboardLayout')
            Policies                   = @()
            Wsus                       = $null
            PendingReboot              = (Get-LPPendingReboot)
            ExecutionPolicy            = $null
        }
        try { $machine.Policies = @(Get-LPPolicyValues -Base $hklm -Root '' -Scope Machine -Label 'This PC') } catch { $errors.Add("Machine policies: $($_.Exception.Message)") }
        $wu = 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        $svc = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing'
        $machine.Wsus = [pscustomobject]@{
            UseWUServer               = (Get-LPRegValue $hklm "$wu\AU" 'UseWUServer')
            WUServer                  = (Get-LPRegValue $hklm $wu 'WUServer')
            RepairContentServerSource = (Get-LPRegValue $hklm $svc 'RepairContentServerSource')
            LocalSourcePath           = (Get-LPRegValue $hklm $svc 'LocalSourcePath')
            UseWindowsUpdate          = (Get-LPRegValue $hklm $svc 'UseWindowsUpdate')
        }
        try { $machine.ExecutionPolicy = [string](Get-ExecutionPolicy -Scope MachinePolicy) } catch { }

        # --- keyboard layouts installed on this PC ---
        $layouts = @()
        try { $layouts = @(Get-LPKeyboardLayouts) } catch { $errors.Add("Keyboard layouts: $($_.Exception.Message)") }

        # --- user profiles ---
        $signedIn = Get-LPSignedInUsers
        $loaded = @(Get-LPLoadedHives)
        $profiles = New-Object System.Collections.Generic.List[object]
        foreach ($p in (Get-LPProfiles)) {
            $isSignedIn = $signedIn.ContainsKey($p.Sid)
            $isLoaded = $loaded -contains $p.Sid
            $method = 'Offline'
            if ($isSignedIn) { $method = 'Task' } elseif ($isLoaded) { $method = 'Loaded' }
            $t = [pscustomobject]@{
                Id            = "user:$($p.Sid)"
                Kind          = 'User'
                Sid           = $p.Sid
                Name          = $p.Name
                ProfilePath   = $p.ProfilePath
                HivePath      = $p.HivePath
                HiveExists    = $p.HiveExists
                SignedIn      = $isSignedIn
                SessionIds    = @(if ($isSignedIn) { $signedIn[$p.Sid].SessionIds })
                HiveLoaded    = $isLoaded
                IsProcessUser = ($p.Sid -eq $proc.Sid)
                Method        = $method
                State         = $null
                StateError    = $null
                Policies      = @()
            }
            if ($isLoaded -or -not $SkipOfflineHives) {
                try {
                    $res = Use-LPHive -Sid $p.Sid -HivePath $p.HivePath -Label $p.Sid -Action {
                        param($b, $r)
                        [pscustomobject]@{ State = (Get-LPHiveState -Base $b -Root $r -Layouts $layouts); Policies = @(Get-LPPolicyValues -Base $b -Root $r -Scope User -Label $p.Name) }
                    }
                    $t.State = $res.State
                    $t.Policies = $res.Policies
                }
                catch {
                    $t.StateError = $_.Exception.Message
                    Write-LPLog "Profile $($p.Name): $($_.Exception.Message)" -Level Warn
                }
            }
            $profiles.Add($t)
        }

        # --- lock screen (.DEFAULT = SYSTEM) and new users (Default profile) ---
        $lock = [pscustomobject]@{ Id = 'lockscreen'; Kind = 'LockScreen'; Name = 'Lock/welcome screen and system accounts'; State = $null; StateError = $null; Policies = @() }
        try {
            $lock.State = Get-LPHiveState -Base $hku -Root '.DEFAULT' -Layouts $layouts
            $lock.Policies = @(Get-LPPolicyValues -Base $hku -Root '.DEFAULT' -Scope User -Label 'Lock screen (.DEFAULT)')
        }
        catch { $lock.StateError = $_.Exception.Message }
        $defHive = Get-LPDefaultProfileHive
        $newUsers = [pscustomobject]@{ Id = 'newusers'; Kind = 'NewUsers'; Name = 'New user accounts (Default profile)'; HivePath = $defHive; State = $null; StateError = $null; Policies = @() }
        if (-not $SkipOfflineHives) {
            try {
                $res = Use-LPHive -HivePath $defHive -Label 'DefaultUser' -Action {
                    param($b, $r)
                    [pscustomobject]@{ State = (Get-LPHiveState -Base $b -Root $r -Layouts $layouts); Policies = @(Get-LPPolicyValues -Base $b -Root $r -Scope User -Label 'Default profile') }
                }
                $newUsers.State = $res.State
                $newUsers.Policies = $res.Policies
            }
            catch { $newUsers.StateError = $_.Exception.Message; Write-LPLog "Default profile: $($_.Exception.Message)" -Level Warn }
        }

        foreach ($e in $errors) { Write-LPLog $e -Level Warn }
        Write-LPLog ('Scan finished: {0} profile(s), {1} signed in.' -f $profiles.Count, @($profiles | Where-Object { $_.SignedIn }).Count) -Level OK
        return [pscustomobject]@{
            ScanTime        = (Get-Date)
            Os              = $os
            Process         = $proc
            Capabilities    = $caps
            Languages       = $languages
            Machine         = $machine
            Profiles        = $profiles.ToArray()
            LockScreen      = $lock
            NewUsers        = $newUsers
            KeyboardLayouts = $layouts
            Errors          = $errors.ToArray()
        }
    }

    function Get-LPTargets {
        param([Parameter(Mandatory)]$Snapshot)
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($p in $Snapshot.Profiles) { $list.Add($p) }
        $list.Add($Snapshot.LockScreen)
        $list.Add($Snapshot.NewUsers)
        return $list.ToArray()
    }

    function Get-LPDefaultTargetIds {
        param([Parameter(Mandatory)]$Snapshot)
        $ids = New-Object System.Collections.Generic.List[string]
        foreach ($p in $Snapshot.Profiles) { if ($p.SignedIn) { $ids.Add($p.Id) } }
        $ids.Add('lockscreen')
        $ids.Add('newusers')
        return $ids.ToArray()
    }

    # Resolves CLI -Target values to target IDs.
    function Resolve-LPTargetIds {
        param([Parameter(Mandatory)]$Snapshot, [string[]]$Target)
        $vals = @($Target | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($vals.Count -eq 0) { return @(Get-LPDefaultTargetIds $Snapshot) }
        $ids = New-Object System.Collections.Generic.List[string]
        foreach ($v in $vals) {
            switch -Regex ($v) {
                '^SignedIn$' { foreach ($p in $Snapshot.Profiles) { if ($p.SignedIn -and -not $ids.Contains($p.Id)) { $ids.Add($p.Id) } }; break }
                '^AllUsers$' { foreach ($p in $Snapshot.Profiles) { if (-not $ids.Contains($p.Id)) { $ids.Add($p.Id) } }; break }
                '^LockScreen$' { if (-not $ids.Contains('lockscreen')) { $ids.Add('lockscreen') }; break }
                '^NewUsers$' { if (-not $ids.Contains('newusers')) { $ids.Add('newusers') }; break }
                default {
                    $match = $null
                    foreach ($p in $Snapshot.Profiles) {
                        $acct = ($p.Name -split '\\')[-1]
                        if ($p.Sid -eq $v -or $p.Name -eq $v -or $acct -eq $v) { $match = $p; break }
                    }
                    if (-not $match) { throw "No user profile matches -Target '$v'. Use SignedIn, AllUsers, LockScreen, NewUsers, a SID or an account name." }
                    if (-not $ids.Contains($match.Id)) { $ids.Add($match.Id) }
                }
            }
        }
        return $ids.ToArray()
    }

    function Find-LPTarget {
        param([Parameter(Mandatory)]$Snapshot, [string]$Id)
        foreach ($t in (Get-LPTargets $Snapshot)) { if ($t.Id -eq $Id) { return $t } }
        return $null
    }

    # --------------------------------------------------------------------------------------------
    # Report lines (rendered by the CLI as text and by the UI as colored rows)
    #   Level: Heading1 Heading2 OK Auto Blocked Warn Risk Info Set Remove Install Keep Text
    # --------------------------------------------------------------------------------------------
    function New-LPLine {
        param([string]$Level = 'Text', [string]$Text, [string[]]$Detail, [string[]]$Steps)
        return [pscustomobject]@{ Level = $Level; Text = $Text; Detail = @($Detail | Where-Object { $_ }); Steps = @($Steps | Where-Object { $_ }) }
    }

    function Format-LPReportText {
        param($Lines)
        $sb = New-Object System.Text.StringBuilder
        foreach ($l in @($Lines)) {
            if ($null -eq $l) { continue }
            $prefix = switch ($l.Level) {
                'Heading1' { '' } 'Heading2' { '' } 'OK' { '[OK]       ' } 'Auto' { '[AUTO]     ' } 'Blocked' { '[BLOCKED]  ' }
                'Warn' { '[WARNING]  ' } 'Risk' { '[RE-ADD]   ' } 'Info' { '[INFO]     ' } 'Set' { '  set      ' } 'Remove' { '  remove   ' }
                'Install' { '  install  ' } 'Keep' { '  keep     ' } default { '' }
            }
            if ($l.Level -eq 'Heading1') { [void]$sb.AppendLine(''); [void]$sb.AppendLine('== ' + $l.Text + ' ==') }
            elseif ($l.Level -eq 'Heading2') { [void]$sb.AppendLine('-- ' + $l.Text) }
            else { [void]$sb.AppendLine($prefix + $l.Text) }
            foreach ($d in @($l.Detail)) { [void]$sb.AppendLine('             ' + $d) }
            foreach ($s in @($l.Steps)) { [void]$sb.AppendLine('             - ' + $s) }
        }
        return $sb.ToString()
    }

    function Write-LPReport {
        param($Lines)
        foreach ($l in @($Lines)) {
            if ($null -eq $l) { continue }
            $color = switch ($l.Level) {
                'Heading1' { 'Cyan' } 'Heading2' { 'White' } 'OK' { 'Green' } 'Auto' { 'Cyan' } 'Blocked' { 'Red' } 'Warn' { 'Yellow' }
                'Risk' { 'Magenta' } 'Remove' { 'Yellow' } 'Install' { 'Cyan' } 'Keep' { 'DarkGray' } default { 'Gray' }
            }
            $txt = (Format-LPReportText @($l)).TrimEnd()
            Write-Host $txt -ForegroundColor $color
        }
    }

    # --------------------------------------------------------------------------------------------
    # Readiness check (pure: works on a snapshot + selection, no changes, no slow I/O)
    #   Part IDs: pack, machine, syslocale, uninstall, lockscreen, newusers, user:<SID>, all
    # --------------------------------------------------------------------------------------------
    function Test-LPReadiness {
        param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)]$Selection)
        $items = New-Object System.Collections.Generic.List[object]
        $blocked = @{}
        $add = {
            param([string]$Id, [string]$Title, [string]$State, [string[]]$Detail, [string[]]$Steps, [string[]]$Blocks)
            $items.Add([pscustomobject]@{ Id = $Id; Title = $Title; State = $State; Detail = @($Detail | Where-Object { $_ }); Steps = @($Steps | Where-Object { $_ }); Blocks = @($Blocks | Where-Object { $_ }) })
            foreach ($b in @($Blocks)) { if ($b) { if (-not $blocked.ContainsKey($b)) { $blocked[$b] = New-Object System.Collections.Generic.List[string] }; $blocked[$b].Add($Title) } }
        }
        $os = $Snapshot.Os
        $caps = $Snapshot.Capabilities
        $langs = $Snapshot.Languages
        $disp = $Selection.DisplayLanguage
        $isWin11 = ($os -and $os.IsWin11)

        $userIds = @($Selection.TargetIds | Where-Object { $_ -like 'user:*' })
        $wantLock = @($Selection.TargetIds) -contains 'lockscreen'
        $wantNew = @($Selection.TargetIds) -contains 'newusers'
        $settingParts = New-Object System.Collections.Generic.List[string]
        foreach ($u in $userIds) { $settingParts.Add($u) }
        if ($wantLock) { $settingParts.Add('lockscreen') }
        if ($wantNew) { $settingParts.Add('newusers') }
        $sp = $settingParts.ToArray()

        # --- display language / pack ---
        $cat = Find-LPDisplayLanguage $disp
        $dispInstalled = $false
        if ($disp) { $dispInstalled = @($langs.Installed) -contains $disp }
        $dispFull = ($disp -and (@($langs.FullPack) -contains $disp))
        $cabCapable = ($cat -and ($cat.Type -eq 'LP' -or ($cat.Type -eq 'LIPCAB' -and $isWin11)))
        # Windows 10: a display language installed only as LXP cannot be used for the welcome screen.
        # If the full pack can be installed, do that instead of blocking the lock screen.
        $packUpgrade = ($wantLock -and -not $isWin11 -and $dispInstalled -and -not $dispFull -and $cabCapable -and ($caps.InstallLanguage -or $Selection.LanguageSource))
        $packNeeded = ($disp -and (-not $dispInstalled -or $packUpgrade))
        $packMethod = 'None'
        $packCab = $null

        $allParts = New-Object System.Collections.Generic.List[string]
        foreach ($x in $sp) { $allParts.Add($x) }
        if ($packNeeded -and $sp.Count -gt 0) { $allParts.Add('pack') }
        if ($Selection.BlockRemoteKeyboard) { $allParts.Add('machine') }
        if ($Selection.SetSystemLocale) { $allParts.Add('syslocale') }
        if ($Selection.UninstallOthers) { $allParts.Add('uninstall') }
        $everything = @($allParts.ToArray() + 'all')

        # 1. Something selected
        if ($sp.Count -eq 0 -and $allParts.Count -eq 0) {
            & $add 'targets' 'Nothing selected' 'Blocked' @('Select at least one user, the lock screen or new users.') $null @('all')
        }
        elseif ($sp.Count -eq 0) {
            & $add 'targets' 'No accounts selected - only the machine options will be applied' 'Info' $null $null $null
        }

        # 2. Admin rights / language mode
        if (-not $Snapshot.Process.IsAdmin) {
            & $add 'admin' 'Administrator rights are missing' 'Blocked' @("The tool runs as $($Snapshot.Process.UserName) without elevation.") @('Start LanguageProfile.cmd again and confirm the UAC prompt (any administrator account works).') $everything
        }
        else {
            & $add 'admin' ('Running elevated as ' + $Snapshot.Process.UserName) 'OK' @('Target accounts are handled by SID; the elevated account is only changed if you select it.') $null $null
        }
        if ($Snapshot.Process.LanguageMode -ne 'FullLanguage') {
            & $add 'langmode' "PowerShell runs in $($Snapshot.Process.LanguageMode) mode" 'Blocked' @('AppLocker or WDAC script enforcement restricts PowerShell. The tool needs FullLanguage mode.') @('Ask IT to allow this script (sign it or add an AppLocker/WDAC rule), then run it again.') $everything
        }

        # 3. Windows version and capabilities
        if ($os) {
            $tested = ($os.Build -eq 19045 -or $os.Build -eq 22631 -or $os.Build -eq 26100 -or $os.Build -eq 26200)
            $capText = @(
                ('Install-Language: ' + $(if ($caps.InstallLanguage) { 'available' } else { 'not available (language packs must be added manually)' }))
                ('Set-SystemPreferredUILanguage: ' + $(if ($caps.SetSystemPreferredUILanguage) { 'available' } else { 'not available (welcome-screen language comes from the lock-screen account settings only)' }))
                'Lock screen and new users are written directly by this tool on every Windows version (README: "Lock screen and new users").'
            )
            if ($tested) { & $add 'windows' $os.Name 'OK' $capText $null $null }
            else { & $add 'windows' ($os.Name + ' - not one of the tested versions (Windows 10 22H2, Windows 11 23H2/24H2/25H2)') 'Warn' $capText $null $null }
        }

        # 4. Display language
        $dispLcid = $Selection.DisplayLcid
        if (-not $disp) {
            & $add 'display' 'No display language selected' 'Blocked' $null $null $sp
        }
        elseif (-not (Get-LPCultureInfo $disp)) {
            & $add 'display' "Unknown display language '$disp'" 'Blocked' $null $null $sp
        }
        elseif ($dispLcid -eq 4096 -or $dispLcid -le 0) {
            & $add 'display' "$disp has no Windows language ID (LCID 4096)" 'Blocked' @('Keyboards are attached to the display language as LLLL:KKKKKKKK, which needs a real language ID. Pick another display language.') $null $sp
        }
        else {
            $name = $disp
            if ($cat) { $name = '{0} ({1})' -f $cat.Name, $disp }
            if ($dispInstalled -and -not $packUpgrade) {
                & $add 'pack' "Display language pack $name is installed" 'OK' $null $null $null
            }
            else {
                $manualUser = "On this PC: Settings > Time & language > Language & region > Add a language > $name > install the language pack, restart, then run this tool again."
                $manualIt = "IT: DISM /Online /Add-Package /PackagePath:<ISO>\LanguagesAndOptionalFeatures\Microsoft-Windows-Client-Language-Pack_x64_$($disp.ToLowerInvariant()).cab (from the 'Languages and Optional Features' ISO that matches build $($os.Build)), restart, then run this tool again - or run this tool with -LanguageSource <folder with that CAB>."
                if ($os -and $os.SingleLanguage) {
                    & $add 'pack' "$name is not installed, and this Windows edition ($($os.EditionId)) cannot add display languages" 'Blocked' @('Windows Home Single Language / Country Specific editions are limited to one display language.') @('Upgrade the edition (e.g. to Pro), then run the tool again.') @('pack')
                }
                else {
                    if ($Selection.LanguageSource) {
                        $packCab = Find-LPLanguageCab -Folder $Selection.LanguageSource -Tag $disp
                        if ($packCab) { $packMethod = 'Source' }
                    }
                    if ($packUpgrade) { $name = "$name (full pack - only the LXP is installed, the welcome screen needs the full pack)" }
                    if ($packMethod -eq 'None' -and $caps.InstallLanguage -and ($cabCapable -or -not $cat)) { $packMethod = 'InstallLanguage' }
                    switch ($packMethod) {
                        'Source' {
                            & $add 'pack' "Display language pack $name will be added automatically from $packCab" 'Auto' @('Installed with DISM (Add-WindowsPackage) from the source folder. Optional features (typing, OCR, speech) are not installed. A restart is needed afterwards.') $null $null
                        }
                        'InstallLanguage' {
                            $d = @('Installed with Install-Language' + $(if ($caps.InstallLanguageExcludeFeatures) { ' -ExcludeFeatures' } else { '' }) + ' from Windows Update or WSUS. This can take 10 minutes or more; progress and a Cancel button are shown. A restart is needed afterwards.',
                                'Install-Language is used WITHOUT -CopyToSettings: that switch would also set the system locale and the language''s default keyboard (US for en-US) for the device. This tool sets those explicitly.')
                            if (-not $cat) { $d += "$disp is not in the built-in list of Windows display languages; the installation will be attempted anyway." }
                            if ($Selection.LanguageSource) { $d += "No matching CAB was found in $($Selection.LanguageSource); falling back to Windows Update/WSUS." }
                            & $add 'pack' "Display language pack $name will be added automatically" 'Auto' $d $null $null
                            $w = $Snapshot.Machine.Wsus
                            if ($w -and [string]$w.UseWUServer -eq '1' -and [string]$w.RepairContentServerSource -ne '2' -and -not $w.LocalSourcePath) {
                                & $add 'wsus' 'WSUS is configured - the language pack download may be blocked (error 0x800f0954)' 'Warn' @("This PC gets updates from WSUS ($($w.WUServer)). WSUS usually does not host language packs, and no alternative source is configured.") @(
                                    'IT: enable the policy "Specify settings for optional component installation and component repair" (Computer Configuration > Administrative Templates > System) and tick "Download repair content and optional features directly from Windows Update instead of Windows Server Update Services (WSUS)", then run gpupdate /force.',
                                    'Or provide a source: copy the language pack CAB from the "Languages and Optional Features" ISO to a share and run this tool with that folder as language pack source.') $null
                            }
                        }
                        default {
                            $steps = @($manualUser)
                            $detail = @()
                            if ($cat -and $cat.Type -ne 'LP') {
                                $detail += "$name is a Local Experience Pack (LXP) language. It is installed from the Microsoft Store through Settings and needs the base language $(@($cat.Base) -join ' or ') to be installed."
                            }
                            elseif (-not $caps.InstallLanguage) {
                                $detail += 'Install-Language (LanguagePackManagement module) is not available on this Windows version.'
                                $steps += $manualIt
                            }
                            else { $steps += $manualIt }
                            & $add 'pack' "Display language pack $name is not installed and cannot be added automatically" 'Blocked' $detail $steps @('pack')
                        }
                    }
                }
            }
        }

        # 5. Lock-screen suitability
        if ($wantLock -and $disp -and $dispLcid -gt 0 -and $dispLcid -ne 4096) {
            $isFull = @($langs.FullPack) -contains $disp
            $willBeFull = (($packMethod -eq 'InstallLanguage' -or $packMethod -eq 'Source') -and (-not $cat -or $cat.Type -ne 'LIP'))
            if ($isFull -or $willBeFull) {
                & $add 'lockpack' 'The display language can be used for the welcome screen' 'OK' $null $null $null
            }
            elseif ($dispInstalled) {
                $d = @("$disp is installed only as a Local Experience Pack (LXP). The welcome screen and system accounts use the system UI language, which needs the full language pack (CAB).")
                $s = @("IT: add the full pack with DISM /Online /Add-Package /PackagePath:<ISO>\LanguagesAndOptionalFeatures\Microsoft-Windows-Client-Language-Pack_x64_$($disp.ToLowerInvariant()).cab, restart, then run the tool again.")
                if ($isWin11) {
                    & $add 'lockpack' "Welcome screen may show $disp only partially (LXP only)" 'Warn' ($d + 'On Windows 11 the welcome screen falls back to the base language for missing text. Keyboards and formats are applied anyway.') $s $null
                }
                else {
                    & $add 'lockpack' "$disp cannot be used for the welcome screen on Windows 10 (LXP only)" 'Blocked' $d $s @('lockscreen')
                }
            }
        }

        # 6. Keyboards
        $layouts = @($Snapshot.KeyboardLayouts)
        if (@($Selection.Keyboards).Count -eq 0 -and @($Selection.InvalidKeyboards).Count -eq 0) {
            & $add 'keyboards' 'No keyboard layout selected' 'Blocked' @('Select at least one keyboard layout.') $null $sp
        }
        foreach ($bad in @($Selection.InvalidKeyboards)) {
            & $add "kb:$bad" "Keyboard '$bad' is not a layout ID" 'Blocked' @('Layout IDs have 8 hex digits, e.g. 00000807 (Swiss German).') $null $sp
        }
        foreach ($k in @($Selection.Keyboards)) {
            $l = $null
            foreach ($x in $layouts) { if ($x.Id -eq $k) { $l = $x; break } }
            if (-not $l) {
                & $add "kb:$k" "Keyboard layout $k is not installed on this PC" 'Blocked' @("There is no HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\$k key. Built-in Windows layouts always exist, so this is a custom layout.") @('Install the custom layout first (for example the setup.exe that Microsoft Keyboard Layout Creator builds, or the vendor installer), then run this tool again.') $sp
            }
            elseif (-not $l.FileExists) {
                & $add "kb:$k" "Keyboard layout $($l.Name) ($k) is registered but its file $($l.File) is missing" 'Blocked' $null @('Reinstall the custom layout, then run this tool again.') $sp
            }
            else {
                & $add "kb:$k" "Keyboard $($l.Name) ($k) is installed" 'OK' $null $null $null
            }
        }
        if ($disp -and @($Selection.Tips).Count -gt 0) {
            $first = ConvertFrom-LPTip $Selection.Tips[0]
            $note = "Keyboards are attached to $disp as " + (@($Selection.Tips) -join ', ') + '. The language list contains only the display language, so Windows cannot re-add its default keyboard.'
            if ($first -and $first.Layout -ne ('0000' + $first.Lang)) {
                $abbr = ''
                try { $abbr = ([Globalization.CultureInfo]::GetCultureInfo($disp)).ThreeLetterWindowsLanguageName } catch { }
                $note += " Side effect: the taskbar shows '$abbr' while you type with $(Get-LPLayoutName $first.Layout $layouts). This is expected."
            }
            & $add 'kbnote' 'Keyboard note' 'Info' @($note) $null $null
        }

        # 7. Regional format and country/region
        $fc = Get-LPCultureInfo $Selection.RegionalFormat
        if (-not $Selection.RegionalFormat -or -not $fc) {
            & $add 'format' "Regional format '$($Selection.RegionalFormat)' is unknown" 'Blocked' $null $null $sp
        }
        elseif ($fc.IsNeutralCulture) {
            & $add 'format' "Regional format '$($Selection.RegionalFormat)' is a neutral culture" 'Blocked' @('Pick a specific culture with a country, e.g. de-CH instead of de.') $null $sp
        }
        else {
            & $add 'format' "Regional format $($fc.EnglishName) ($($fc.Name))" 'OK' @('Built into Windows, nothing to download. Not added to the language list (it would create a second entry in the switcher).') $null $null
        }
        if ($Selection.GeoId -le 0) {
            & $add 'geo' 'No country/region selected' 'Blocked' $null $null $sp
        }
        else {
            & $add 'geo' ('Country/region: {0} (GeoId {1})' -f (Get-LPGeoName $Selection.GeoId), $Selection.GeoId) 'OK' $null $null $null
        }

        # 8. Environment: pending restart
        $pr = $Snapshot.Machine.PendingReboot
        if ($pr -and $pr.Pending) {
            $servicing = @(@('pack', 'uninstall', 'syslocale') | Where-Object { $allParts.Contains($_) })
            if ($servicing.Count -gt 0) {
                & $add 'reboot' 'A restart is pending - restart first' 'Blocked' $pr.Reasons @('Restart the PC, then run this tool again. (Installing or removing language packs on top of a pending restart is unreliable.)') $servicing
            }
            else {
                & $add 'reboot' 'A restart is pending' 'Warn' ($pr.Reasons + 'The settings can be applied; restart the PC afterwards.') $null $null
            }
        }

        # 9. Policies (machine + each selected target)
        foreach ($pol in @($Snapshot.Machine.Policies | Where-Object { $_ })) {
            $e = Get-LPPolicyEffect -Policy $pol -Selection $Selection
            $bl = @()
            switch ($e.Blocks) {
                'pack' { $bl = @(@('pack', 'uninstall') | Where-Object { $allParts.Contains($_) }) }
                'ui' { $bl = $sp }
                'format' { $bl = $sp }
                'geo' { $bl = $sp }
            }
            & $add "policy:machine:$($pol.Name)" ('This PC: ' + $e.Text) $e.State $e.Detail $null $bl
        }
        foreach ($tid in $sp) {
            $t = Find-LPTarget $Snapshot $tid
            if (-not $t) { continue }
            foreach ($pol in @($t.Policies | Where-Object { $_ })) {
                $e = Get-LPPolicyEffect -Policy $pol -Selection $Selection
                $bl = @()
                if ($e.Blocks) { $bl = @($tid) }
                & $add "policy:$tid`:$($pol.Name)" ("$($t.Name): " + $e.Text) $e.State $e.Detail $null $bl
            }
        }

        # 10. Targets
        foreach ($tid in $userIds) {
            $t = Find-LPTarget $Snapshot $tid
            if (-not $t) { & $add "target:$tid" "Selected user $tid no longer exists" 'Blocked' $null $null @($tid); continue }
            if ($t.SignedIn) {
                if (-not $Snapshot.Capabilities.TaskScheduler) {
                    & $add "target:$tid" "$($t.Name) is signed in, but the Task Scheduler service is not running" 'Blocked' @('Signed-in users are configured inside their own session through a one-time scheduled task.') @('Start the "Task Scheduler" service, then run the tool again.') @($tid)
                }
                else {
                    & $add "target:$tid" "$($t.Name) (signed in): applied inside the user's session" 'OK' @('A one-time scheduled task runs the language cmdlets as this user; it is deleted afterwards. Sign-out needed for the display language.', 'If PowerShell is blocked or restricted for this user (security software, AppLocker / App Control), the settings are written directly into the profile instead and take effect after sign-out and sign-in.') $null $null
                }
            }
            elseif ($t.HiveLoaded) {
                & $add "target:$tid" "$($t.Name): profile is loaded without a desktop session - written directly" 'OK' $null $null $null
            }
            elseif (-not $t.HiveExists) {
                & $add "target:$tid" "$($t.Name): NTUSER.DAT not found - will be skipped" 'Warn' @("Expected at $($t.HivePath).") $null $null
            }
            elseif ($t.StateError) {
                & $add "target:$tid" "$($t.Name): profile could not be read - will be skipped if still locked" 'Warn' @($t.StateError) $null $null
            }
            else {
                & $add "target:$tid" "$($t.Name) (not signed in): written into the profile, active at next sign-in" 'OK' $null $null $null
            }
        }
        if ($wantNew -and $Snapshot.NewUsers.StateError) {
            & $add 'target:newusers' 'Default profile could not be read' 'Warn' @($Snapshot.NewUsers.StateError) $null $null
        }
        $offlineSelected = @($userIds | Where-Object { $t = Find-LPTarget $Snapshot $_; $t -and -not $t.SignedIn }).Count -gt 0
        if (-not $wantLock -and ($wantNew -or $offlineSelected)) {
            & $add 'reference' 'The lock-screen account is used as a temporary reference' 'Info' @('Settings for profiles that are not signed in and for new users are generated by Windows itself in the SYSTEM account (= lock screen), copied, and the lock screen is then restored to its previous state.') $null $null
        }

        # 11. Options
        if ($Selection.BlockRemoteKeyboard) {
            if ([string]$Snapshot.Machine.IgnoreRemoteKeyboardLayout -eq '1') { & $add 'rdp' 'Remote Desktop keyboard injection is already blocked' 'OK' $null $null $null }
            else { & $add 'rdp' 'Remote Desktop keyboard injection will be blocked (IgnoreRemoteKeyboardLayout = 1)' 'Auto' @('RDP/Citrix clients can no longer add their own keyboard layout to sessions on this PC.') $null $null }
        }
        if ($Selection.SetSystemLocale) {
            $sl = Get-LPCultureInfo $Selection.SystemLocale
            if (-not $sl -or $sl.IsNeutralCulture) { & $add 'syslocale' "System locale '$($Selection.SystemLocale)' is not valid" 'Blocked' $null $null @('syslocale') }
            elseif ($Snapshot.Languages.SystemLocale -eq $sl.Name) { & $add 'syslocale' "System locale is already $($sl.Name)" 'OK' $null $null $null }
            else { & $add 'syslocale' "System locale will be set to $($sl.Name) (was $($Snapshot.Languages.SystemLocale))" 'Auto' @('Needs a restart. Programs that are not Unicode may show garbled text if they expect another code page.') $null $null }
        }
        if ($Selection.UninstallOthers) {
            $keep = @($disp)
            if (-not $wantLock -and $Snapshot.Languages.SystemPreferredUILanguage) { $keep += $Snapshot.Languages.SystemPreferredUILanguage }
            $remove = @($langs.Installed | Where-Object { $keep -notcontains $_ })
            if ($remove.Count -eq 0) {
                & $add 'uninstall' 'Uninstall other language packs: there are none - en-US is the only display language pack on this PC' 'OK' @(
                    'A display language pack is the translated Windows interface (Settings shows "language pack" under the language). Languages that are only in a language list, for example English (United Kingdom) without a pack, are not packs. The profile removes them from the lists of the selected accounts anyway (see the preview).') $null $null
            }
            elseif (-not $caps.UninstallLanguage) {
                & $add 'uninstall' ('Other language packs (' + ($remove -join ', ') + ') cannot be removed automatically') 'Blocked' @('Uninstall-Language is not available on this Windows version.') @('Settings > Time & language > Language & region > (language) > Remove, or IT: DISM /Online /Remove-Package for the language pack package.') @('uninstall')
            }
            else {
                $d = @('Not rolled back by Restore. Needs a restart. Windows may refuse to remove the language it was installed with; that is reported, not fatal.')
                $users = @()
                foreach ($p in $Snapshot.Profiles) {
                    if (@($Selection.TargetIds) -contains $p.Id) { continue }
                    if ($p.State -and $p.State.UILanguage -and $remove -contains $p.State.UILanguage) { $users += ('{0} ({1})' -f $p.Name, $p.State.UILanguage) }
                }
                if ($users.Count -gt 0) { $d += ('These NOT selected users use one of them as display language and will fall back: ' + ($users -join ', ')) }
                if (-not $wantLock) { $d += "The system UI language $($Snapshot.Languages.SystemPreferredUILanguage) is kept because the lock screen is not selected." }
                $d = @('Display language packs (translated Windows interface) are removed for the whole PC. Languages that are only in a language list are removed from the selected accounts anyway.') + $d
                & $add 'uninstall' ('Display language packs to uninstall: ' + ($remove -join ', ')) 'Auto' $d $null $null
            }
        }
        if ($sp.Count -gt 0) {
            if ($Selection.DisableSync) { & $add 'sync' 'Language settings sync will be disabled for the targets' 'Info' @('Prevents Windows settings sync from restoring an old language list.') $null $null }
            else { & $add 'sync' 'Language settings sync stays as it is' 'Warn' @('Settings sync can bring back old language lists and keyboards.') $null $null }
        }
        & $add 'features' 'Optional language features (basic typing, OCR, speech) are not required' 'Info' @('They are not installed by this tool and not reported as errors. Windows may download some in the background.') $null $null

        # Cascade: without the display language pack the account settings would make Windows re-add
        # the current display language with its default keyboard, so they are blocked too.
        if ($blocked.ContainsKey('pack') -and $packNeeded) {
            $cascade = $sp
            if ($packUpgrade) { $cascade = @('lockscreen') }
            foreach ($x in $cascade) { if (-not $blocked.ContainsKey($x)) { $blocked[$x] = New-Object System.Collections.Generic.List[string] }; $blocked[$x].Add('display language pack missing') }
        }

        $blockedParts = @($blocked.Keys)
        $ready = @()
        if (-not $blocked.ContainsKey('all')) { $ready = @($allParts | Where-Object { -not $blocked.ContainsKey($_) }) }
        $hasBlocked = @($items | Where-Object { $_.State -eq 'Blocked' }).Count -gt 0
        $nothing = ($allParts.Count -eq 0)
        return [pscustomobject]@{
            Items              = $items.ToArray()
            AllParts           = $allParts.ToArray()
            BlockedParts       = $blockedParts
            ReadyParts         = $ready
            HasBlocked         = $hasBlocked
            CanApply           = (-not $hasBlocked -and -not $nothing)
            CanApplyReadyParts = ($hasBlocked -and $ready.Count -gt 0)
            PackNeeded         = [bool]$packNeeded
            PackMethod         = $packMethod
            PackCab            = $packCab
        }
    }

    function Find-LPLanguageCab {
        param([string]$Folder, [string]$Tag)
        if (-not $Folder -or -not (Test-Path -LiteralPath $Folder)) { return $null }
        $t = $Tag.ToLowerInvariant()
        $cands = @(Get-ChildItem -LiteralPath $Folder -Filter '*.cab' -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'Client-Language-Pack' -and $_.Name.ToLowerInvariant() -match ('_' + [regex]::Escape($t) + '\.cab$') })
        $arch = 'x64'
        if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'arm64' }
        $best = @($cands | Where-Object { $_.Name -match "_$arch`_" })
        if ($best.Count -gt 0) { return $best[0].FullName }
        if ($cands.Count -gt 0) { return $cands[0].FullName }
        return $null
    }

    function Get-LPReadinessLines {
        param([Parameter(Mandatory)]$Readiness)
        $lines = New-Object System.Collections.Generic.List[object]
        $lines.Add((New-LPLine 'Heading1' 'Readiness'))
        $order = @{ Blocked = 0; Warn = 1; Auto = 2; OK = 3; Info = 4 }
        foreach ($i in @($Readiness.Items | Sort-Object { $order[$_.State] })) { $lines.Add((New-LPLine $i.State $i.Title $i.Detail $i.Steps)) }
        return $lines.ToArray()
    }

    function Get-LPReadinessSummary {
        param([Parameter(Mandatory)]$Readiness)
        $b = @($Readiness.Items | Where-Object { $_.State -eq 'Blocked' }).Count
        $a = @($Readiness.Items | Where-Object { $_.State -eq 'Auto' }).Count
        $w = @($Readiness.Items | Where-Object { $_.State -eq 'Warn' }).Count
        if ($b -gt 0) {
            $s = "$b item(s) BLOCKED - nothing will be changed unless you explicitly choose to apply only the parts that are ready."
            if (-not $Readiness.CanApplyReadyParts) { $s = "$b item(s) BLOCKED - nothing can be applied until they are fixed." }
            return $s
        }
        if (@($Readiness.AllParts).Count -eq 0) { return 'Nothing selected.' }
        return ("Ready. {0} item(s) will be added automatically, {1} warning(s)." -f $a, $w)
    }

    # --------------------------------------------------------------------------------------------
    # Desired state, differences, compliance and re-add risks
    # --------------------------------------------------------------------------------------------
    function Get-LPLanguageListText {
        param($State, $Layouts)
        if (-not $State -or @($State.Languages).Count -eq 0) { return '(no language list)' }
        $parts = foreach ($l in $State.Languages) {
            $tips = @($State.LanguageTips[$l])
            $names = @($tips | ForEach-Object { $p = ConvertFrom-LPTip $_; if ($p) { Get-LPLayoutName $p.Layout $Layouts } else { $_ } })
            '{0} [{1}]' -f $l, ($names -join ', ')
        }
        return ($parts -join '; ')
    }

    # Returns the issues that make a state differ from the selection (empty = compliant).
    function Test-LPStateCompliance {
        param($State, [Parameter(Mandatory)]$Selection, [string]$Kind = 'User', [string]$SystemUILanguage)
        $issues = New-Object System.Collections.Generic.List[string]
        if (-not $State) { $issues.Add('state could not be read'); return $issues.ToArray() }
        $langs = @($State.Languages)
        if ($langs.Count -ne 1 -or $langs[0] -ne $Selection.DisplayLanguage) { $issues.Add('language list is [' + ($langs -join ', ') + '], expected [' + $Selection.DisplayLanguage + ']') }
        $tips = @()
        if ($langs.Count -gt 0 -and $State.LanguageTips.Contains($Selection.DisplayLanguage)) { $tips = @($State.LanguageTips[$Selection.DisplayLanguage]) }
        # Tips are compared as a set (Windows' order values are not guaranteed); the default is checked separately.
        if ((@($tips | Sort-Object) -join ',') -ne (@($Selection.Tips | Sort-Object) -join ',')) { $issues.Add('keyboards are [' + (@($State.Tips) -join ', ') + '], expected [' + (@($Selection.Tips) -join ', ') + ']') }
        elseif ($State.InputMethodOverride -and @($Selection.Tips).Count -gt 0 -and ([string]$State.InputMethodOverride).ToUpperInvariant() -ne $Selection.Tips[0]) { $issues.Add("default keyboard is $($State.InputMethodOverride), expected $($Selection.Tips[0])") }
        $ui = $State.UILanguage
        if (-not $ui -and $Kind -ne 'NewUsers') { $ui = $SystemUILanguage }
        if ($ui -ne $Selection.DisplayLanguage) { $issues.Add("display language is '$ui', expected '$($Selection.DisplayLanguage)'") }
        if ($State.Format -ne $Selection.RegionalFormat) { $issues.Add("regional format is '$($State.Format)', expected '$($Selection.RegionalFormat)'") }
        if ([int]$State.GeoId -ne [int]$Selection.GeoId) { $issues.Add("country/region is $($State.GeoId), expected $($Selection.GeoId)") }
        if ((@($State.PreloadTips) -join ',') -ne (@($Selection.Tips) -join ',')) { $issues.Add('Preload is [' + (@($State.PreloadTips) -join ', ') + '], expected [' + (@($Selection.Tips) -join ', ') + ']') }
        if ($Selection.DisableSync -and $Kind -ne 'LockScreen' -and [string]$State.SyncEnabled -ne '0') { $issues.Add('language sync is not disabled') }
        if ($State.PSObject.Properties['BackupLanguages']) {
            $bl = @($State.BackupLanguages)
            if ($State.BackupExists -and (($bl -join ',') -ne $Selection.DisplayLanguage -or (@($State.BackupTips | Sort-Object) -join ',') -ne (@($Selection.Tips | Sort-Object) -join ','))) {
                $issues.Add('language list backup (User Profile System Backup) is [' + ($bl -join ', ') + ': ' + (@($State.BackupTips) -join ', ') + ']')
            }
            if (@($State.CtfForeignLangIds).Count -gt 0) {
                $issues.Add('text input (CTF) still has entries for ' + (@($State.CtfForeignLangIds | ForEach-Object { Get-LPLangIdDisplay $_ }) -join ', '))
            }
        }
        return $issues.ToArray()
    }

    function Test-LPCompliance {
        param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)]$Selection)
        $res = New-Object System.Collections.Generic.List[object]
        foreach ($id in @($Selection.TargetIds)) {
            $t = Find-LPTarget $Snapshot $id
            if (-not $t) { continue }
            $issues = @(Test-LPStateCompliance -State $t.State -Selection $Selection -Kind $t.Kind -SystemUILanguage $Snapshot.Languages.SystemPreferredUILanguage)
            if ($id -eq 'lockscreen' -and $Snapshot.Capabilities.GetSystemPreferredUILanguage -and $Snapshot.Languages.SystemPreferredUILanguage -ne $Selection.DisplayLanguage) {
                $issues += "system preferred UI language is $($Snapshot.Languages.SystemPreferredUILanguage)"
            }
            $res.Add([pscustomobject]@{ Id = $id; Name = $t.Name; Compliant = ($issues.Count -eq 0); Issues = $issues })
        }
        if ($Selection.BlockRemoteKeyboard) {
            $ok = ([string]$Snapshot.Machine.IgnoreRemoteKeyboardLayout -eq '1')
            $iss = @()
            if (-not $ok) { $iss = @('IgnoreRemoteKeyboardLayout is not 1') }
            $res.Add([pscustomobject]@{ Id = 'machine'; Name = 'This PC'; Compliant = $ok; Issues = $iss })
        }
        return $res.ToArray()
    }

    function Get-LPRisks {
        param($State, [string]$Kind, $LockState, [string]$SystemUILanguage, $Layouts)
        $r = New-Object System.Collections.Generic.List[string]
        if (-not $State) { return $r.ToArray() }
        $langs = @($State.Languages)
        $ui = $State.UILanguage
        if (-not $ui) { $ui = $State.MachineUILanguage }
        if (-not $ui) { $ui = $SystemUILanguage }
        if ($langs.Count -eq 0) {
            $r.Add('No language list: Windows builds one at first sign-in from the system language, including its default keyboard.')
        }
        elseif ($ui -and -not ($langs -contains $ui)) {
            $r.Add("The display language $ui is not in the language list: Windows re-adds it WITH ITS DEFAULT KEYBOARD.")
        }
        if (@($State.Hidden).Count -gt 0) {
            $names = @($State.Hidden | ForEach-Object { Get-LPTipDisplay $_ $Layouts })
            $r.Add('Hidden layouts in Keyboard Layout\Preload that are not in the language list (they reappear): ' + ($names -join '; '))
        }
        if ($Kind -eq 'User' -and $LockState) {
            $extra = @($LockState.Tips | Where-Object { -not (@($State.Tips) -contains $_) })
            if ($extra.Count -gt 0) {
                $r.Add('The lock screen has layouts this user does not have (pulled into the session at sign-in): ' + (@($extra | ForEach-Object { Get-LPTipDisplay $_ $Layouts }) -join '; '))
            }
        }
        if ($Kind -ne 'LockScreen' -and [string]$State.SyncEnabled -ne '0') {
            $r.Add('Language settings sync is not disabled: sync can restore an old language list.')
        }
        if ($langs.Count -gt 1) {
            $r.Add('More than one language in the list: each one adds its own entry (e.g. a second "DEU") to the switcher.')
        }
        if ($State.PSObject.Properties['BackupLanguages'] -and $State.BackupExists) {
            $bl = @($State.BackupLanguages)
            $extraTips = @($State.BackupTips | Where-Object { -not (@($State.Tips) -contains $_) })
            $extraLangs = @($bl | Where-Object { -not ($langs -contains $_) })
            if ($extraTips.Count -gt 0 -or $extraLangs.Count -gt 0) {
                $what = @()
                if ($extraLangs.Count) { $what += 'languages ' + ($extraLangs -join ', ') }
                if ($extraTips.Count) { $what += 'keyboards ' + (@($extraTips | ForEach-Object { Get-LPTipDisplay $_ $Layouts }) -join '; ') }
                $r.Add("Windows' backup of the language list (User Profile System Backup) still has " + ($what -join ' and ') + ' - Windows can restore it.')
            }
        }
        if ($State.PSObject.Properties['CtfForeignLangIds'] -and @($State.CtfForeignLangIds).Count -gt 0) {
            $r.Add('Text input settings (CTF) still have entries for languages that are not in the list: ' + (@($State.CtfForeignLangIds | ForEach-Object { Get-LPLangIdDisplay $_ }) -join ', '))
        }
        return $r.ToArray()
    }

    function Get-LPStateLines {
        param($State, $Layouts, [string]$SystemUILanguage)
        $lines = New-Object System.Collections.Generic.List[object]
        if (-not $State) { return $lines.ToArray() }
        $ui = $State.UILanguage
        $uiText = $ui
        if (-not $ui) { $uiText = '(not set - uses system language {0})' -f $SystemUILanguage }
        if ($State.UILanguagePending) { $uiText += " (pending after sign-out: $($State.UILanguagePending))" }
        if ($State.PSObject.Properties['UILanguageOverride'] -and $State.UILanguageOverride -and $State.UILanguageCurrent -and $State.UILanguageCurrent -ne $State.UILanguageOverride) { $uiText += " (currently $($State.UILanguageCurrent), changes at next sign-in)" }
        $lines.Add((New-LPLine 'Text' ('Display language:   ' + $uiText)))
        $lines.Add((New-LPLine 'Text' ('Regional format:    ' + $(if ($State.Format) { $State.Format } else { '(not set)' }))))
        $lines.Add((New-LPLine 'Text' ('Country/region:     ' + $(if ($State.GeoId) { '{0} ({1})' -f (Get-LPGeoName $State.GeoId), $State.GeoId } else { '(not set)' }))))
        $lines.Add((New-LPLine 'Text' ('Language list:      ' + (Get-LPLanguageListText $State $Layouts))))
        if ($State.InputMethodOverride) { $lines.Add((New-LPLine 'Text' ('Default keyboard:   ' + (Get-LPTipDisplay $State.InputMethodOverride $Layouts)))) }
        if ($State.PSObject.Properties['BackupExists'] -and $State.BackupExists) {
            $lines.Add((New-LPLine 'Text' ('List backup:        ' + (@($State.BackupLanguages) -join ', ') + ' [' + (@($State.BackupTips | ForEach-Object { $p = ConvertFrom-LPTip $_; if ($p) { Get-LPLayoutName $p.Layout $Layouts } else { $_ } }) -join ', ') + ']')))
        }
        if ($State.PSObject.Properties['CtfLangIds']) {
            $lines.Add((New-LPLine 'Text' ('Text input (CTF):   ' + $(if (@($State.CtfLangIds).Count) { (@($State.CtfLangIds | ForEach-Object { Get-LPLangIdDisplay $_ }) -join ', ') } else { '(none)' }))))
        }
        $pre = @($State.PreloadTips | ForEach-Object { Get-LPTipDisplay $_ $Layouts })
        $lines.Add((New-LPLine 'Text' ('Preload:            ' + $(if ($pre.Count) { $pre -join '; ' } else { '(empty)' }))))
        $syncText = '(not set - on if sync is used)'
        if ($null -ne $State.SyncEnabled) { $syncText = $(if ([string]$State.SyncEnabled -eq '0') { 'disabled' } else { 'enabled' }) }
        $lines.Add((New-LPLine 'Text' ('Language sync:      ' + $syncText)))
        return $lines.ToArray()
    }

    function Get-LPStatusLines {
        param([Parameter(Mandatory)]$Snapshot, $Selection)
        $lines = New-Object System.Collections.Generic.List[object]
        $layouts = $Snapshot.KeyboardLayouts
        $sysUi = $Snapshot.Languages.SystemPreferredUILanguage
        $lines.Add((New-LPLine 'Heading1' 'This PC'))
        if ($Snapshot.Os) { $lines.Add((New-LPLine 'Text' $Snapshot.Os.Name)) }
        $lines.Add((New-LPLine 'Text' ('Installed display languages: ' + ((@($Snapshot.Languages.Installed | ForEach-Object { if (@($Snapshot.Languages.FullPack) -contains $_) { "$_ (full pack)" } else { "$_ (LXP only)" } })) -join ', '))))
        $lines.Add((New-LPLine 'Text' ('System UI language: ' + $sysUi + '   System locale: ' + $Snapshot.Languages.SystemLocale + '   Installed with: ' + $Snapshot.Languages.InstallLanguage)))
        if ([string]$Snapshot.Machine.IgnoreRemoteKeyboardLayout -eq '1') { $lines.Add((New-LPLine 'OK' 'Remote Desktop keyboard injection is blocked (IgnoreRemoteKeyboardLayout = 1)')) }
        else { $lines.Add((New-LPLine 'Risk' 'Remote Desktop/Citrix can inject the client keyboard layout (IgnoreRemoteKeyboardLayout is not 1)')) }
        if ($Snapshot.Machine.PendingReboot.Pending) { $lines.Add((New-LPLine 'Warn' 'A restart is pending' $Snapshot.Machine.PendingReboot.Reasons)) }
        foreach ($pol in @($Snapshot.Machine.Policies | Where-Object { $_ })) { $lines.Add((New-LPLine 'Warn' ('Policy: {0} = {1}' -f $pol.Name, $pol.Value) @("$($pol.Key) ($($pol.Source))"))) }
        foreach ($e in @($Snapshot.Errors)) { $lines.Add((New-LPLine 'Warn' $e)) }

        $targets = @()
        $targets += $Snapshot.Profiles
        $targets += $Snapshot.LockScreen
        $targets += $Snapshot.NewUsers
        foreach ($t in $targets) {
            $title = $t.Name
            if ($t.Kind -eq 'User') {
                if ($t.SignedIn) { $title += '  -  signed in' } elseif ($t.HiveLoaded) { $title += '  -  profile loaded (no desktop session)' } else { $title += '  -  not signed in' }
                if ($t.IsProcessUser) { $title += '  -  this is the elevated account running the tool' }
            }
            $lines.Add((New-LPLine 'Heading1' $title))
            if ($t.StateError) { $lines.Add((New-LPLine 'Warn' ('Could not read: ' + $t.StateError))); continue }
            if (-not $t.State) { $lines.Add((New-LPLine 'Info' 'Not read')); continue }
            foreach ($l in (Get-LPStateLines -State $t.State -Layouts $layouts -SystemUILanguage $sysUi)) { $lines.Add($l) }
            if (@($t.State.Hidden).Count -gt 0) {
                $lines.Add((New-LPLine 'Warn' ('HIDDEN layouts: ' + (@($t.State.Hidden | ForEach-Object { Get-LPTipDisplay $_ $layouts }) -join '; '))))
            }
            foreach ($risk in (Get-LPRisks -State $t.State -Kind $t.Kind -LockState $Snapshot.LockScreen.State -SystemUILanguage $sysUi -Layouts $layouts)) { $lines.Add((New-LPLine 'Risk' $risk)) }
            if ($t.PSObject.Properties['Policies']) {
                foreach ($pol in @($t.Policies | Where-Object { $_ })) { $lines.Add((New-LPLine 'Warn' ('Policy: {0} = {1}' -f $pol.Name, $pol.Value) @("$($pol.Key) ($($pol.Source))"))) }
            }
            if ($Selection) {
                $iss = @(Test-LPStateCompliance -State $t.State -Selection $Selection -Kind $t.Kind -SystemUILanguage $sysUi)
                if ($iss.Count -eq 0) { $lines.Add((New-LPLine 'OK' 'Matches the selected profile')) }
                else { $lines.Add((New-LPLine 'Info' 'Differs from the selected profile' $iss)) }
            }
        }
        return $lines.ToArray()
    }

    # --------------------------------------------------------------------------------------------
    # Plan / preview
    # --------------------------------------------------------------------------------------------
    function Get-LPTargetChangeLines {
        param($State, [Parameter(Mandatory)]$Selection, $Layouts, [string]$Kind, [string]$SystemUILanguage)
        $lines = New-Object System.Collections.Generic.List[object]
        $disp = $Selection.DisplayLanguage
        $cur = $null
        if ($State) { $cur = $State.UILanguage }
        if (-not $cur -and $Kind -ne 'NewUsers') { $cur = $SystemUILanguage }
        $kbNames = @($Selection.Keyboards | ForEach-Object { '{0} ({1})' -f (Get-LPLayoutName $_ $Layouts), $_ })
        $lines.Add((New-LPLine $(if ($cur -eq $disp) { 'Keep' } else { 'Set' }) ("Display language: $disp" + $(if ($cur -and $cur -ne $disp) { "   (was $cur)" } else { '' }))))
        $lines.Add((New-LPLine 'Set' ("Language list: only $disp, with keyboard(s) " + ($kbNames -join ', ') + '   [' + (@($Selection.Tips) -join ', ') + ']')))
        $lines.Add((New-LPLine 'Set' ('Default keyboard: ' + $kbNames[0])))
        $curFmt = $null; $curGeo = 0
        if ($State) { $curFmt = $State.Format; $curGeo = [int]$State.GeoId }
        $lines.Add((New-LPLine $(if ($curFmt -eq $Selection.RegionalFormat) { 'Keep' } else { 'Set' }) ("Regional format: $($Selection.RegionalFormat)" + $(if ($curFmt -and $curFmt -ne $Selection.RegionalFormat) { "   (was $curFmt)" } else { '' }))))
        $lines.Add((New-LPLine $(if ($curGeo -eq $Selection.GeoId) { 'Keep' } else { 'Set' }) ('Country/region: {0} ({1})' -f (Get-LPGeoName $Selection.GeoId), $Selection.GeoId)))
        if ($State) {
            foreach ($l in @($State.Languages)) {
                if ($l -ne $disp) {
                    $kt = @($State.LanguageTips[$l] | ForEach-Object { Get-LPTipDisplay $_ $Layouts })
                    $lines.Add((New-LPLine 'Remove' ("Language $l" + $(if ($kt.Count) { ' with ' + ($kt -join ', ') } else { ' (no keyboards)' }))))
                }
                else {
                    foreach ($t in @($State.LanguageTips[$l])) { if (-not (@($Selection.Tips) -contains $t)) { $lines.Add((New-LPLine 'Remove' ('Keyboard ' + (Get-LPTipDisplay $t $Layouts)))) } }
                }
            }
            foreach ($h in @($State.Hidden)) { $lines.Add((New-LPLine 'Remove' ('Hidden layout ' + (Get-LPTipDisplay $h $Layouts) + ' (Keyboard Layout\Preload)'))) }
            if ($State.PSObject.Properties['BackupExists'] -and $State.BackupExists) {
                $oldTips = @($State.BackupTips | Where-Object { -not (@($Selection.Tips) -contains $_) })
                $oldLangs = @($State.BackupLanguages | Where-Object { $_ -ne $disp })
                if ($oldTips.Count -or $oldLangs.Count) {
                    $lines.Add((New-LPLine 'Remove' ('From the list backup (User Profile System Backup): ' + ((@($oldLangs) + @($oldTips | ForEach-Object { Get-LPTipDisplay $_ $Layouts })) -join ', '))))
                }
            }
            $ctfOld = @($State.CtfForeignLangIds | Where-Object { $_ -ne $Selection.DisplayLcid })
            if ($ctfOld.Count) { $lines.Add((New-LPLine 'Remove' ('Text input (CTF) entries for ' + (@($ctfOld | ForEach-Object { Get-LPLangIdDisplay $_ }) -join ', ')))) }
        }
        if ($Selection.DisableSync -and $Kind -ne 'LockScreen') {
            if (-not $State -or [string]$State.SyncEnabled -ne '0') { $lines.Add((New-LPLine 'Set' 'Language settings sync: off')) }
        }
        return $lines.ToArray()
    }

    function New-LPPlan {
        param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)]$Selection, [Parameter(Mandatory)]$Readiness, [switch]$ReadyPartsOnly)
        $parts = @()
        if ($ReadyPartsOnly) { $parts = @($Readiness.ReadyParts) }
        elseif ($Readiness.CanApply) { $parts = @($Readiness.AllParts) }
        $skipped = @($Readiness.AllParts | Where-Object { $parts -notcontains $_ })
        $layouts = $Snapshot.KeyboardLayouts
        $sysUi = $Snapshot.Languages.SystemPreferredUILanguage
        $steps = New-Object System.Collections.Generic.List[object]
        $lines = New-Object System.Collections.Generic.List[object]
        $restart = New-Object System.Collections.Generic.List[string]
        $signOut = New-Object System.Collections.Generic.List[string]
        $nextSignIn = New-Object System.Collections.Generic.List[string]
        $has = { param($p) $parts -contains $p }

        $lines.Add((New-LPLine 'Heading1' ('Profile: {0} display, {1} format, {2}, keyboard(s) {3}' -f $Selection.DisplayLanguage, $Selection.RegionalFormat, (Get-LPGeoName $Selection.GeoId), (@($Selection.Keyboards | ForEach-Object { Get-LPLayoutName $_ $layouts }) -join ', '))))
        if ($parts.Count -eq 0) {
            $lines.Add((New-LPLine 'Blocked' 'Nothing will be changed.' @(Get-LPReadinessSummary $Readiness)))
        }
        if ($ReadyPartsOnly -and $skipped.Count -gt 0) {
            $lines.Add((New-LPLine 'Warn' 'PARTIAL APPLY - these parts are blocked and will NOT be changed:' @($skipped | ForEach-Object { $t = Find-LPTarget $Snapshot $_; if ($t) { $t.Name } else { $_ } })))
        }

        # Order matters: pack first (if it fails nothing else is done), then machine settings, then
        # the SYSTEM reference (= lock screen), the copies, the signed-in users, uninstall last.
        if (& $has 'pack') {
            $steps.Add([pscustomobject]@{ Kind = 'InstallPack'; Part = 'pack'; Title = "Install display language pack $($Selection.DisplayLanguage)"; Method = $Readiness.PackMethod; Cab = $Readiness.PackCab })
            $lines.Add((New-LPLine 'Heading2' 'Language pack'))
            $lines.Add((New-LPLine 'Install' ("Display language pack $($Selection.DisplayLanguage)" + $(if ($Readiness.PackMethod -eq 'Source') { " from $($Readiness.PackCab)" } else { ' via Install-Language (Windows Update/WSUS, 10+ minutes)' }))))
            $restart.Add('a display language pack was installed')
        }
        $machineLines = New-Object System.Collections.Generic.List[object]
        if ((& $has 'lockscreen') -and $Snapshot.Capabilities.SetSystemPreferredUILanguage) {
            $steps.Add([pscustomobject]@{ Kind = 'SystemUILanguage'; Part = 'lockscreen'; Title = "Set system preferred UI language to $($Selection.DisplayLanguage)" })
            if ($sysUi -ne $Selection.DisplayLanguage) { $machineLines.Add((New-LPLine 'Set' "System preferred UI language: $($Selection.DisplayLanguage)   (was $sysUi)")) }
        }
        if (& $has 'machine') {
            $steps.Add([pscustomobject]@{ Kind = 'RemoteKeyboard'; Part = 'machine'; Title = 'Block Remote Desktop keyboard injection' })
            if ([string]$Snapshot.Machine.IgnoreRemoteKeyboardLayout -ne '1') { $machineLines.Add((New-LPLine 'Set' 'HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layout\IgnoreRemoteKeyboardLayout = 1')) }
        }
        if (& $has 'syslocale') {
            $steps.Add([pscustomobject]@{ Kind = 'SystemLocale'; Part = 'syslocale'; Title = "Set system locale to $($Selection.SystemLocale)" })
            if ($Snapshot.Languages.SystemLocale -ne $Selection.SystemLocale) {
                $machineLines.Add((New-LPLine 'Set' "System locale (non-Unicode programs): $($Selection.SystemLocale)   (was $($Snapshot.Languages.SystemLocale))"))
                $restart.Add('the system locale changed')
            }
        }
        if ($machineLines.Count -gt 0) { $lines.Add((New-LPLine 'Heading2' 'This PC')); foreach ($m in $machineLines) { $lines.Add($m) } }

        $userParts = @($parts | Where-Object { $_ -like 'user:*' })
        $needsReference = (& $has 'lockscreen') -or (& $has 'newusers') -or (@($userParts | Where-Object { $t = Find-LPTarget $Snapshot $_; $t -and -not $t.SignedIn }).Count -gt 0)
        if ($needsReference) {
            $steps.Add([pscustomobject]@{ Kind = 'Reference'; Part = 'lockscreen'; Title = 'Apply the profile to the SYSTEM account (lock screen) as reference'; KeepLockScreen = [bool](& $has 'lockscreen') })
        }
        if (& $has 'lockscreen') {
            $steps.Add([pscustomobject]@{ Kind = 'SystemAccounts'; Part = 'lockscreen'; Title = 'Copy to LocalService and NetworkService' })
            $lines.Add((New-LPLine 'Heading2' 'Lock/welcome screen and system accounts (HKU\.DEFAULT, S-1-5-19, S-1-5-20)'))
            foreach ($l in (Get-LPTargetChangeLines -State $Snapshot.LockScreen.State -Selection $Selection -Layouts $layouts -Kind 'LockScreen' -SystemUILanguage $sysUi)) { $lines.Add($l) }
            $restart.Add('the lock/welcome screen changed')
        }
        if (& $has 'newusers') {
            $steps.Add([pscustomobject]@{ Kind = 'NewUsers'; Part = 'newusers'; Title = 'Write the Default profile (new users)'; HivePath = $Snapshot.NewUsers.HivePath })
            $lines.Add((New-LPLine 'Heading2' "New user accounts (Default profile: $($Snapshot.NewUsers.HivePath))"))
            foreach ($l in (Get-LPTargetChangeLines -State $Snapshot.NewUsers.State -Selection $Selection -Layouts $layouts -Kind 'NewUsers' -SystemUILanguage $sysUi)) { $lines.Add($l) }
        }
        foreach ($uid in $userParts) {
            $t = Find-LPTarget $Snapshot $uid
            if (-not $t) { continue }
            $steps.Add([pscustomobject]@{ Kind = 'User'; Part = $uid; Title = "Apply to $($t.Name)"; Sid = $t.Sid; Name = $t.Name; HivePath = $t.HivePath })
            $how = switch ($t.Method) { 'Task' { 'signed in: applied inside the session by a one-time scheduled task' } 'Loaded' { 'profile loaded: written directly' } default { 'not signed in: written into NTUSER.DAT, active at next sign-in' } }
            $lines.Add((New-LPLine 'Heading2' "$($t.Name)   ($how)"))
            foreach ($l in (Get-LPTargetChangeLines -State $t.State -Selection $Selection -Layouts $layouts -Kind 'User' -SystemUILanguage $sysUi)) { $lines.Add($l) }
            if ($t.SignedIn) { $signOut.Add($t.Name) } else { $nextSignIn.Add($t.Name) }
        }
        if ($needsReference -and -not (& $has 'lockscreen')) {
            $steps.Add([pscustomobject]@{ Kind = 'RestoreReference'; Part = 'lockscreen'; Title = 'Restore the lock screen (it was only used as reference)' })
        }
        if (& $has 'uninstall') {
            $keep = @($Selection.DisplayLanguage)
            if (-not (& $has 'lockscreen') -and $sysUi) { $keep += $sysUi }
            $remove = @($Snapshot.Languages.Installed | Where-Object { $keep -notcontains $_ })
            if ($remove.Count -gt 0) {
                $steps.Add([pscustomobject]@{ Kind = 'Uninstall'; Part = 'uninstall'; Title = 'Uninstall other language packs'; Languages = $remove })
                $lines.Add((New-LPLine 'Heading2' 'Language packs'))
                foreach ($r in $remove) { $lines.Add((New-LPLine 'Remove' "Language pack $r (Uninstall-Language)")) }
                $restart.Add('language packs were removed')
            }
        }
        if ($steps.Count -gt 0) {
            $lines.Add((New-LPLine 'Heading2' 'Afterwards'))
            if ($signOut.Count -gt 0) { $lines.Add((New-LPLine 'Info' ('Sign out and in again: ' + ($signOut -join ', ')))) }
            if ($nextSignIn.Count -gt 0) { $lines.Add((New-LPLine 'Info' ('Active at next sign-in: ' + ($nextSignIn -join ', ')))) }
            if ($restart.Count -gt 0) { $lines.Add((New-LPLine 'Info' ('Restart needed: ' + (@($restart | Select-Object -Unique) -join ', ')))) }
            $lines.Add((New-LPLine 'Info' "Every key is exported to a backup folder before it is changed (Restore tab / -Restore)."))
        }
        return [pscustomobject]@{
            Selection      = $Selection
            Parts          = $parts
            SkippedParts   = $skipped
            ReadyPartsOnly = [bool]$ReadyPartsOnly
            Steps          = $steps.ToArray()
            Lines          = $lines.ToArray()
            Executable     = ($steps.Count -gt 0)
            PredictRestart = @($restart | Select-Object -Unique)
            PredictSignOut = $signOut.ToArray()
        }
    }

    function Get-LPPlanSummaryText {
        param([Parameter(Mandatory)]$Plan, $Snapshot)
        $s = $Plan.Selection
        $who = @()
        foreach ($p in @($Plan.Parts)) {
            if ($p -eq 'lockscreen') { $who += 'lock/welcome screen' }
            elseif ($p -eq 'newusers') { $who += 'new users' }
            elseif ($p -like 'user:*' -and $Snapshot) { $t = Find-LPTarget $Snapshot $p; if ($t) { $who += $t.Name } }
        }
        $txt = "Display language: $($s.DisplayLanguage)`nRegional format: $($s.RegionalFormat) / GeoId $($s.GeoId)`nKeyboard(s): $(@($s.Keyboards) -join ', ')`n`nApply to: $(if ($who.Count) { $who -join ', ' } else { '(machine options only)' })"
        if (@($Plan.Steps | Where-Object { $_.Kind -eq 'InstallPack' }).Count -gt 0) { $txt += "`n`nThe display language pack will be installed first (can take 10+ minutes)." }
        if ($Plan.ReadyPartsOnly -and @($Plan.SkippedParts).Count -gt 0) { $txt += "`n`nPARTIAL: blocked parts are skipped and stay unchanged." }
        $txt += "`n`nAll other languages and keyboards are removed from these places. A backup is made first."
        return $txt
    }

    # --------------------------------------------------------------------------------------------
    # Worker: runs INSIDE the target account (signed-in user, or SYSTEM for the lock screen) via a
    # one-time scheduled task. It never runs in the elevated admin's context. Engine helper functions
    # (Preload plan, registry tree copy, backup sync, CTF cleanup) are inserted at #__LP_HELPERS__.
    # --------------------------------------------------------------------------------------------
    $script:WorkerText = @'
param([Parameter(Mandatory = $true)][string]$JobDir)
$ErrorActionPreference = 'Stop'
$outDir = Join-Path $JobDir 'out'
$logFile = Join-Path $outDir 'worker.log'
$result = [ordered]@{ Sid = $null; User = $null; Success = $false; Error = $null; Steps = @(); Warnings = @(); After = $null }

function Write-WorkerLog([string]$Message) {
    try { [IO.File]::AppendAllText($logFile, ('{0:HH:mm:ss} {1}' -f (Get-Date), $Message) + "`r`n", [Text.Encoding]::UTF8) } catch { }
}
function Invoke-WorkerStep([string]$Name, [scriptblock]$Action) {
    Write-WorkerLog "Step: $Name"
    try {
        & $Action
        $result.Steps += [ordered]@{ Name = $Name; Ok = $true; Error = $null }
    }
    catch {
        $msg = $_.Exception.Message
        $result.Steps += [ordered]@{ Name = $Name; Ok = $false; Error = $msg }
        Write-WorkerLog "  FAILED: $msg"
        throw
    }
}

function Write-LPLog([string]$Message, [string]$Level) { Write-WorkerLog $Message }

#__LP_HELPERS__

try {
    $job = [IO.File]::ReadAllText((Join-Path $JobDir 'job.json')) | ConvertFrom-Json
    $me = [Security.Principal.WindowsIdentity]::GetCurrent()
    $result.Sid = $me.User.Value
    $result.User = $me.Name
    Write-WorkerLog "Worker running as $($me.Name) ($($me.User.Value)), PowerShell $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)"
    # Never assume HKCU is the target: refuse to run in any other account.
    if ($me.User.Value -ne $job.ExpectedSid) { throw "Running as $($me.User.Value) but the job is for $($job.ExpectedSid). Nothing was changed." }
    if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'The worker must run in Windows PowerShell 5.1.' }
    Import-Module International -ErrorAction Stop
    $tips = @($job.Tips)

    Invoke-WorkerStep 'Language list (Set-WinUserLanguageList)' {
        $list = New-WinUserLanguageList -Language $job.DisplayLanguage
        $list[0].InputMethodTips.Clear()
        foreach ($t in $tips) { $list[0].InputMethodTips.Add([string]$t) }
        Set-WinUserLanguageList -LanguageList $list -Force
    }
    Invoke-WorkerStep 'Default keyboard (Set-WinDefaultInputMethodOverride)' {
        Set-WinDefaultInputMethodOverride -InputTip ([string]$tips[0])
    }
    Invoke-WorkerStep 'Display language (Set-WinUILanguageOverride)' {
        try { Set-WinUILanguageOverride -Language $job.DisplayLanguage }
        catch {
            # Happens when the language pack was installed a moment ago and is active only after a restart.
            Write-WorkerLog "  Set-WinUILanguageOverride failed ($($_.Exception.Message)); writing Control Panel\Desktop\PreferredUILanguages directly."
            $result.Warnings += "Set-WinUILanguageOverride failed: $($_.Exception.Message). PreferredUILanguages was written directly; it takes effect after the restart."
            $dk = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Control Panel\Desktop')
            try { $dk.SetValue('PreferredUILanguages', [string[]]@($job.DisplayLanguage), [Microsoft.Win32.RegistryValueKind]::MultiString) } finally { $dk.Close() }
        }
    }
    Invoke-WorkerStep 'Regional format (Set-Culture)' { Set-Culture -CultureInfo $job.RegionalFormat }
    Invoke-WorkerStep 'Country/region (Set-WinHomeLocation)' { Set-WinHomeLocation -GeoId ([int]$job.GeoId) }
    Invoke-WorkerStep 'Keyboard Layout\Preload cleanup' {
        $cu = [Microsoft.Win32.Registry]::CurrentUser
        $vals = @()
        $pre = $cu.OpenSubKey('Keyboard Layout\Preload', $false)
        if ($pre) {
            try { foreach ($n in @($pre.GetValueNames() | Where-Object { $_ -match '^\d+$' } | Sort-Object { [int]$_ })) { $vals += [string]$pre.GetValue($n) } }
            finally { $pre.Close() }
        }
        $subs = @{}
        $sk = $cu.OpenSubKey('Keyboard Layout\Substitutes', $false)
        if ($sk) { try { foreach ($n in $sk.GetValueNames()) { $subs[$n] = [string]$sk.GetValue($n) } } finally { $sk.Close() } }
        $plan = Get-LPPreloadPlan -DesiredTips $tips -Preload $vals -Substitutes $subs
        foreach ($r in $plan.Removed) { Write-WorkerLog ("  removed Preload entry {0} ({1})" -f $r.Value, $r.Tip) }
        foreach ($a in $plan.Added) { Write-WorkerLog ("  added Preload entry for {0}" -f $a) }
        $cu.DeleteSubKeyTree('Keyboard Layout\Preload', $false)
        $cu.DeleteSubKeyTree('Keyboard Layout\Substitutes', $false)
        $pk = $cu.CreateSubKey('Keyboard Layout\Preload')
        try { $i = 1; foreach ($v in $plan.Preload) { $pk.SetValue([string]$i, [string]$v, [Microsoft.Win32.RegistryValueKind]::String); $i++ } } finally { $pk.Close() }
        $sk2 = $cu.CreateSubKey('Keyboard Layout\Substitutes')
        try { foreach ($k in @($plan.Substitutes.Keys)) { $sk2.SetValue([string]$k, [string]$plan.Substitutes[$k], [Microsoft.Win32.RegistryValueKind]::String) } } finally { $sk2.Close() }
    }
    Invoke-WorkerStep 'Language list backup (User Profile System Backup)' {
        if (Sync-LPLanguageBackup -Base ([Microsoft.Win32.Registry]::CurrentUser) -Root '') { Write-WorkerLog '  backup now equals the language list' }
    }
    Invoke-WorkerStep 'Text input leftovers (CTF)' {
        foreach ($r in @(Clear-LPCtfLeftovers -Base ([Microsoft.Win32.Registry]::CurrentUser) -Root '' -LangIds @([int]$job.DisplayLcid))) { Write-WorkerLog "  removed $r" }
    }
    if ($job.DisableSync) {
        Invoke-WorkerStep 'Language settings sync off' {
            $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\SettingSync\Groups\Language')
            try { $k.SetValue('Enabled', 0, [Microsoft.Win32.RegistryValueKind]::DWord) } finally { $k.Close() }
        }
    }
    try {
        $after = Get-WinUserLanguageList
        $result.After = [ordered]@{ Languages = @($after | ForEach-Object { [ordered]@{ Tag = $_.LanguageTag; Tips = @($_.InputMethodTips) } }) }
    }
    catch { }
    $result.Success = $true
    Write-WorkerLog 'Done.'
}
catch {
    $result.Error = $_.Exception.Message
    Write-WorkerLog "ERROR: $($_.Exception.Message)"
}
finally {
    $json = $result | ConvertTo-Json -Depth 8
    $tmp = Join-Path $outDir 'result.tmp'
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination (Join-Path $outDir 'result.json') -Force
}
'@

    function Get-LPWorkerScriptText {
        $helpers = foreach ($fn in 'ConvertFrom-LPTip', 'Get-LPPreloadPlan', 'Join-LPRegPath', 'Test-LPRegKey', 'Get-LPRegSubKeyNames', 'Read-LPRegTree',
            'Write-LPRegValues', 'Write-LPRegTree', 'Remove-LPRegTree', 'ConvertFrom-LPLangIdName', 'Sync-LPLanguageBackup', 'Clear-LPCtfLeftovers') {
            "function $fn {`r`n" + (Get-Item -LiteralPath "function:$fn").ScriptBlock.ToString() + "`r`n}`r`n"
        }
        return $script:WorkerText.Replace('#__LP_HELPERS__', ($helpers -join "`r`n"))
    }

    function Set-LPFolderAcl {
        param([string]$Path, [string[]]$Grants, [switch]$Replace)
        $a = @($Path)
        if ($Replace) { $a += '/inheritance:r'; $a += '/grant:r' } else { $a += '/grant' }
        $a += $Grants
        $r = Invoke-LPNative -FilePath (Join-Path $env:SystemRoot 'System32\icacls.exe') -Arguments $a
        if ($r.ExitCode -ne 0) { throw "icacls failed on $Path : $($r.Output)" }
    }

    # Explains why a worker task ended without a result, from the marker files the bootstrap writes.
    function Get-LPWorkerFailure {
        param([Parameter(Mandatory)][string]$OutDir, [string]$Label, [string]$TaskResult)
        $read = { param($f) $p = Join-Path $OutDir $f; if (Test-Path -LiteralPath $p) { (@(Get-Content -LiteralPath $p -Encoding UTF8) -join "`n").Trim() } else { $null } }
        $started = & $read 'started.txt'
        $bootErr = & $read 'bootstrap-error.txt'
        $wlog = & $read 'worker.log'
        $detail = New-Object System.Collections.Generic.List[string]
        if ($TaskResult) { $detail.Add("Task result: $TaskResult") }
        if ($started) { $detail.Add("Bootstrap: $started") }
        if ($bootErr) { $detail.Add("Error: $bootErr") }
        if ($wlog) { foreach ($l in ($wlog -split "`n")) { $detail.Add("Worker: $l") } }
        $reason = 'PowerShell in the session ended without a result.'
        $mode = $null
        if ($started -match 'mode=(\w+)') { $mode = $Matches[1] }
        if (-not $started) {
            $reason = "PowerShell did not start in $Label's session, or was stopped immediately (security software or a policy that blocks PowerShell for this user?)."
        }
        elseif ($mode -and $mode -ne 'FullLanguage') {
            $reason = "PowerShell runs in $mode mode for $Label (AppLocker / App Control policy), so the language cmdlets cannot run in the session."
        }
        elseif ($bootErr) {
            $first = ($bootErr -split "`n")[0]
            $reason = "The worker could not run in $Label's session: $first"
            if ($bootErr -match '(?i)malicious|antivirus|AMSI') { $reason += ' (blocked by the antivirus / AMSI)' }
        }
        elseif ($wlog) {
            $reason = "The worker in $Label's session stopped before it finished (killed by security software?). Last log line: " + (($wlog -split "`n")[-1])
        }
        return [pscustomobject]@{ Reason = $reason; LanguageMode = $mode; Detail = $detail.ToArray(); WorkerStarted = [bool]$wlog }
    }

    # Bootstrap of the worker task, passed with -EncodedCommand (no quoting issues; an enforced execution
    # policy does not apply to it). It only uses cmdlets, so it also works in Constrained Language Mode and
    # reports that mode, or any error, through marker files in out\.
    function Get-LPWorkerBootstrap {
        param([Parameter(Mandatory)][string]$OutDir, [Parameter(Mandatory)][string]$WorkerPath, [Parameter(Mandatory)][string]$JobDir)
        $q = { param($t) $t.Replace("'", "''") }
        return (@(
                ("`$o = '{0}'" -f (& $q $OutDir))
                '$m = [string]$ExecutionContext.SessionState.LanguageMode'
                'Set-Content -LiteralPath (Join-Path $o ''started.txt'') -Value (''started '' + (Get-Date -Format s) + '' mode='' + $m)'
                'if ($m -ne ''FullLanguage'') { exit 3 }'
                ("try {{ & ([scriptblock]::Create((Get-Content -LiteralPath '{0}' -Raw -Encoding UTF8))) -JobDir '{1}' }}" -f (& $q $WorkerPath), (& $q $JobDir))
                'catch { Set-Content -LiteralPath (Join-Path $o ''bootstrap-error.txt'') -Value ($_ | Out-String); exit 4 }'
            ) -join "`n")
    }

    # Runs the worker as $Sid through a one-time scheduled task, waits, returns the result, cleans up.
    # Never throws after the task was created: failures come back as Success = $false with a reason.
    function Invoke-LPWorkerTask {
        param([Parameter(Mandatory)][string]$Sid, [Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)]$Selection, [int]$TimeoutMinutes = 10)
        $isSystem = ($Sid -eq 'S-1-5-18')
        $guid = [guid]::NewGuid().ToString('N').Substring(0, 12)
        $jobDir = Join-Path (Join-Path $script:DataRoot 'Jobs') $guid
        $outDir = Join-Path $jobDir 'out'
        $taskName = "LanguageProfile-$guid"
        $registered = $false
        $fail = { param($Reason, $Detail) [pscustomobject]@{ Success = $false; Error = $Reason; Detail = @($Detail); Steps = @(); Warnings = @(); After = $null; RunAs = $null; WorkerStarted = $false } }
        try {
            $null = New-Item -ItemType Directory -Path $outDir -Force
            # Job folder: SYSTEM + Administrators full; the target user may read it and write only to out\.
            $grants = @('*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
            if (-not $isSystem) { $grants += "*$($Sid):(OI)(CI)RX" }
            Set-LPFolderAcl -Path $jobDir -Grants $grants -Replace
            if (-not $isSystem) { Set-LPFolderAcl -Path $outDir -Grants @("*$($Sid):(OI)(CI)M") }

            $job = [ordered]@{
                ExpectedSid     = $Sid
                DisplayLanguage = $Selection.DisplayLanguage
                DisplayLcid     = [int]$Selection.DisplayLcid
                RegionalFormat  = $Selection.RegionalFormat
                GeoId           = [int]$Selection.GeoId
                Tips            = @($Selection.Tips)
                DisableSync     = [bool]($Selection.DisableSync -and -not $isSystem)
            }
            $utf8 = New-Object Text.UTF8Encoding($false)
            [IO.File]::WriteAllText((Join-Path $jobDir 'job.json'), ($job | ConvertTo-Json -Depth 5), $utf8)
            $workerPath = Join-Path $jobDir 'worker.ps1'
            [IO.File]::WriteAllText($workerPath, (Get-LPWorkerScriptText), $utf8)

            $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((Get-LPWorkerBootstrap -OutDir $outDir -WorkerPath $workerPath -JobDir $jobDir)))
            $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $action = New-ScheduledTaskAction -Execute $psExe -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $enc"
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes ($TimeoutMinutes + 2)) -MultipleInstances IgnoreNew
            $principals = @()
            if ($isSystem) {
                $principals += New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
                $principals += New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            }
            else {
                $principals += New-ScheduledTaskPrincipal -UserId $Sid -LogonType Interactive -RunLevel Limited
                $acct = $null
                try { $acct = (New-Object Security.Principal.SecurityIdentifier($Sid)).Translate([Security.Principal.NTAccount]).Value } catch { }
                if ($acct) { $principals += New-ScheduledTaskPrincipal -UserId $acct -LogonType Interactive -RunLevel Limited }
            }
            $lastErr = $null
            foreach ($pr in $principals) {
                try {
                    $task = New-ScheduledTask -Action $action -Principal $pr -Settings $settings -Description 'Language Profile: one-time worker, deleted automatically.'
                    $null = Register-ScheduledTask -TaskPath $script:TaskPath -TaskName $taskName -InputObject $task -Force -ErrorAction Stop
                    $registered = $true
                    break
                }
                catch { $lastErr = $_.Exception.Message }
            }
            if (-not $registered) { return (& $fail "Could not create the scheduled task for $Label : $lastErr" @()) }

            Write-LPLog "Running the language cmdlets as $Label (task $($script:TaskPath)$taskName)..." -Level Detail
            $started = Get-Date
            Start-ScheduledTask -TaskPath $script:TaskPath -TaskName $taskName
            $resultFile = Join-Path $outDir 'result.json'
            $deadline = $started.AddMinutes($TimeoutMinutes)
            $sawRunning = $false
            $ended = $null
            while (-not (Test-Path -LiteralPath $resultFile)) {
                if ((Get-Date) -gt $deadline) { $ended = "did not finish within $TimeoutMinutes minutes"; break }
                Start-Sleep -Milliseconds 700
                $t = Get-ScheduledTask -TaskPath $script:TaskPath -TaskName $taskName -ErrorAction SilentlyContinue
                if (-not $t) { continue }
                if ([string]$t.State -eq 'Running') { $sawRunning = $true; continue }
                $info = Get-ScheduledTaskInfo -InputObject $t -ErrorAction SilentlyContinue
                if ($info -and $info.LastRunTime -and $info.LastRunTime -ge $started.AddSeconds(-5) -and $info.LastTaskResult -ne 267009 -and $info.LastTaskResult -ne 267011) {
                    Start-Sleep -Seconds 2
                    if (-not (Test-Path -LiteralPath $resultFile)) { $ended = ('ended with result 0x{0:X8} after {1:N0} s' -f $info.LastTaskResult, ((Get-Date) - $started).TotalSeconds) }
                    break
                }
                if (-not $sawRunning -and ((Get-Date) - $started).TotalSeconds -gt 90) { $ended = 'did not start within 90 seconds (is the session still active?)'; break }
            }
            if (-not (Test-Path -LiteralPath $resultFile)) {
                $f = Get-LPWorkerFailure -OutDir $outDir -Label $Label -TaskResult $ended
                Write-LPLog ("The task for $Label $ended. " + $f.Reason) -Level Warn
                foreach ($d in $f.Detail) { Write-LPLog ("  [$Label] $d") -Level Detail }
                $r = & $fail $f.Reason $f.Detail
                $r.WorkerStarted = $f.WorkerStarted
                return $r
            }
            $res = [IO.File]::ReadAllText($resultFile) | ConvertFrom-Json
            $logLines = @()
            $wl = Join-Path $outDir 'worker.log'
            if (Test-Path -LiteralPath $wl) { $logLines = @(Get-Content -LiteralPath $wl -Encoding UTF8) }
            foreach ($l in $logLines) { Write-LPLog ("  [$Label] $l") -Level Detail }
            return [pscustomobject]@{ Success = [bool]$res.Success; Error = $res.Error; Detail = @(); Steps = @($res.Steps); Warnings = @($res.Warnings); After = $res.After; RunAs = $res.User; WorkerStarted = $true }
        }
        catch {
            return (& $fail ("Running the worker for {0} failed: {1}" -f $Label, $_.Exception.Message) @())
        }
        finally {
            if ($registered) { try { Unregister-ScheduledTask -TaskPath $script:TaskPath -TaskName $taskName -Confirm:$false -ErrorAction Stop } catch { Write-LPLog "Could not delete task $taskName : $($_.Exception.Message)" -Level Warn } }
            try { Remove-Item -LiteralPath $jobDir -Recurse -Force -ErrorAction Stop } catch { }
        }
    }

    # The SYSTEM account's hive is HKU\.DEFAULT = the lock/welcome screen. Windows' own cmdlets run there
    # and produce the exact values that are then copied elsewhere. On any failure .DEFAULT is put back.
    function New-LPReference {
        param([Parameter(Mandatory)]$Hku, [Parameter(Mandatory)]$Selection, [Parameter(Mandatory)]$Snapshot, [int]$TaskTimeoutMinutes = 10)
        $backup = Backup-LPHive -Base $Hku -Root '.DEFAULT' -Label 'LockScreen_DEFAULT' -TargetId 'lockscreen' -Sid 'S-1-5-18' -Specs $script:LanguageKeySet
        try {
            $w = Invoke-LPWorkerTask -Sid 'S-1-5-18' -Label 'SYSTEM (lock screen)' -Selection $Selection -TimeoutMinutes $TaskTimeoutMinutes
            foreach ($wn in @($w.Warnings)) { if ($wn) { Write-LPLog $wn -Level Warn } }
            if (-not $w.Success) { throw "Applying the profile to the SYSTEM account failed: $($w.Error)" }
            $ref = @(foreach ($s in $script:LanguageKeySet) { Get-LPKeySnapshot -Base $Hku -Root '.DEFAULT' -Spec $s })
            $refState = Get-LPHiveState -Base $Hku -Root '.DEFAULT' -Layouts $Snapshot.KeyboardLayouts
            $iss = @(Test-LPStateCompliance -State $refState -Selection $Selection -Kind 'LockScreen' -SystemUILanguage $Selection.DisplayLanguage)
            if ($iss.Count -gt 0) { throw ('The reference produced by Windows does not match the profile: ' + ($iss -join '; ')) }
            return [pscustomobject]@{ Reference = $ref; Backup = $backup }
        }
        catch {
            try { foreach ($snap in $backup) { Set-LPKeyFromSnapshot -Base $Hku -Root '.DEFAULT' -Snapshot $snap }; Write-LPLog 'Lock screen put back to its previous state.' -Level Warn } catch { }
            throw
        }
    }

    # --------------------------------------------------------------------------------------------
    # Backups
    # --------------------------------------------------------------------------------------------
    function New-LPBackupSession {
        param([string]$Reason = 'apply', $Selection)
        $dir = Join-Path (Join-Path $script:DataRoot 'Backups') ('{0:yyyyMMdd-HHmmss}_{1}' -f (Get-Date), $Reason)
        $null = New-Item -ItemType Directory -Path $dir -Force
        $sel = $null
        if ($Selection) { $sel = $Selection | Select-Object DisplayLanguage, RegionalFormat, GeoId, Keyboards, Tips, TargetIds, DisableSync, BlockRemoteKeyboard, SetSystemLocale, SystemLocale, UninstallOthers }
        $script:CurrentBackup = [pscustomobject]@{
            Path     = $dir
            Manifest = [pscustomobject]@{
                Tool     = 'LanguageProfile'
                Version  = $script:LPVersion
                Created  = (Get-Date).ToString('s')
                Computer = $env:COMPUTERNAME
                RunBy    = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                Reason   = $Reason
                LogFile  = $script:LogFile
                Selection = $sel
                Entries  = @()
            }
        }
        Save-LPBackupManifest
        Write-LPLog "Backup folder: $dir" -Level Detail
        return $dir
    }

    function Save-LPBackupManifest {
        if (-not $script:CurrentBackup) { return }
        $json = $script:CurrentBackup.Manifest | ConvertTo-Json -Depth 40
        [IO.File]::WriteAllText((Join-Path $script:CurrentBackup.Path 'manifest.json'), $json, (New-Object Text.UTF8Encoding($false)))
    }

    # Snapshots (for Restore) + reg export (human-readable copy) of every key we will touch in a hive.
    function Backup-LPHive {
        param([Parameter(Mandatory)]$Base, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Label, [string]$TargetId, [string]$Sid, [string]$HivePath, [Parameter(Mandatory)]$Specs)
        if (-not $script:CurrentBackup) { throw 'No backup session.' }
        $snaps = @(foreach ($s in $Specs) { Get-LPKeySnapshot -Base $Base -Root $Root -Spec $s })
        $files = @()
        $safe = $Label -replace '[^A-Za-z0-9_.-]', '_'
        foreach ($s in $Specs) {
            $file = Join-Path $script:CurrentBackup.Path ('{0}__{1}.reg' -f $safe, $s.Id)
            $r = Invoke-LPReg @('export', ('HKU\' + (Join-LPRegPath $Root $s.Path)), $file, '/y')
            if ($r.ExitCode -eq 0) { $files += (Split-Path -Path $file -Leaf) }
        }
        $entry = [pscustomobject]@{ Kind = 'Hive'; TargetId = $TargetId; Label = $Label; Sid = $Sid; HivePath = $HivePath; RootAtBackup = $Root; Snapshots = $snaps; RegFiles = $files }
        $script:CurrentBackup.Manifest.Entries = @($script:CurrentBackup.Manifest.Entries) + @($entry)
        Save-LPBackupManifest
        return $snaps
    }

    function Backup-LPMachine {
        param([Parameter(Mandatory)]$Snapshot)
        $hklm = Get-LPBaseKey 'LocalMachine'
        $snap = Get-LPKeySnapshot -Base $hklm -Root '' -Spec $script:RemoteKbSpec
        $file = Join-Path $script:CurrentBackup.Path 'Machine__KeyboardLayout.reg'
        $null = Invoke-LPReg @('export', "HKLM\$($script:RemoteKbSpec.Path)", $file, '/y')
        $sysUi = $null
        if ($Snapshot.Capabilities.GetSystemPreferredUILanguage) { $sysUi = $Snapshot.Languages.SystemPreferredUILanguage }
        $entry = [pscustomobject]@{ Kind = 'Machine'; Snapshots = @($snap); SystemPreferredUILanguage = $sysUi; SystemLocale = $Snapshot.Languages.SystemLocale; RegFiles = @('Machine__KeyboardLayout.reg') }
        $script:CurrentBackup.Manifest.Entries = @($script:CurrentBackup.Manifest.Entries) + @($entry)
        Save-LPBackupManifest
    }

    function Get-LPBackups {
        $root = Join-Path $script:DataRoot 'Backups'
        if (-not (Test-Path -LiteralPath $root)) { return @() }
        $list = foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
            $mf = Join-Path $d.FullName 'manifest.json'
            if (-not (Test-Path -LiteralPath $mf)) { continue }
            try {
                $m = [IO.File]::ReadAllText($mf) | ConvertFrom-Json
                $labels = @($m.Entries | ForEach-Object { if ($_.Kind -eq 'Machine') { 'this PC' } else { $_.Label } })
                [pscustomobject]@{ Path = $d.FullName; Name = $d.Name; Created = $m.Created; RunBy = $m.RunBy; Reason = $m.Reason; Targets = ($labels -join ', '); Display = ('{0}   {1}   by {2}   [{3}]' -f $m.Created, $m.Reason, $m.RunBy, ($labels -join ', ')) }
            }
            catch { }
        }
        return @($list)
    }

    # --------------------------------------------------------------------------------------------
    # Language pack install / uninstall (background job: progress + cancel)
    # --------------------------------------------------------------------------------------------
    function Get-LPHResults {
        param([string]$Text)
        $codes = New-Object System.Collections.Generic.List[string]
        foreach ($m in [regex]::Matches($Text, '0x[0-9A-Fa-f]{8}')) { $c = $m.Value.ToLowerInvariant(); if (-not $codes.Contains($c)) { $codes.Add($c) } }
        foreach ($m in [regex]::Matches($Text, '-21474\d{5}|-21\d{8}')) {
            try { $c = ('0x{0:x8}' -f [int]$m.Value); if (-not $codes.Contains($c)) { $codes.Add($c) } } catch { }
        }
        return $codes.ToArray()
    }

    function Get-LPInstallErrorExplanation {
        param([string[]]$Codes, [string]$Tag, [int]$Build)
        $cab = "Microsoft-Windows-Client-Language-Pack_x64_$($Tag.ToLowerInvariant()).cab"
        $manualUser = "User: Settings > Time & language > Language & region > Add a language > $Tag, restart, then run this tool again."
        $manualIt = "IT: DISM /Online /Add-Package /PackagePath:<ISO>\LanguagesAndOptionalFeatures\$cab (ISO 'Languages and Optional Features' for build $Build), restart - or run this tool with the folder containing that CAB as language pack source."
        if ($Codes -contains '0x800f0954') {
            return [pscustomobject]@{ Code = '0x800f0954'; Title = 'The download was blocked by WSUS (0x800f0954)'
                Text = 'Windows tried to get the language pack from the WSUS server, which does not provide language packs or optional features.'
                Steps = @(
                    'IT: enable the policy "Specify settings for optional component installation and component repair" (Computer Configuration > Administrative Templates > System), tick "Download repair content and optional features directly from Windows Update instead of Windows Server Update Services (WSUS)", run gpupdate /force, then run this tool again.',
                    'Or IT provides a source: copy the language pack CAB from the "Languages and Optional Features" ISO to a share and run this tool with that folder as language pack source (UI: Options; CLI: -LanguageSource).',
                    $manualIt) }
        }
        if ($Codes -contains '0x800f081f') {
            return [pscustomobject]@{ Code = '0x800f081f'; Title = 'Windows could not find the language pack source (0x800f081f)'; Text = 'No download source was reachable or the configured source folder does not contain the package.'; Steps = @($manualIt, $manualUser) }
        }
        if ($Codes -contains '0x80070422') {
            return [pscustomobject]@{ Code = '0x80070422'; Title = 'The Windows Update service is disabled (0x80070422)'; Text = 'Install-Language downloads through Windows Update.'; Steps = @('Set the "Windows Update" service to Manual and start it, then run this tool again.', $manualIt) }
        }
        foreach ($c in '0x8024402c', '0x80072ee2', '0x80072ee7', '0x80072efd', '0x80072f8f', '0x8024401c') {
            if ($Codes -contains $c) {
                return [pscustomobject]@{ Code = $c; Title = "Windows Update could not be reached ($c)"; Text = 'No internet connection, a proxy, or a firewall blocks the download.'; Steps = @('Check the network/proxy, then run this tool again.', $manualIt) }
            }
        }
        if ($Codes -contains '0x800f0950') {
            return [pscustomobject]@{ Code = '0x800f0950'; Title = 'The language pack could not be installed (0x800f0950)'; Text = 'Often a download or source problem on managed PCs.'; Steps = @($manualIt, $manualUser) }
        }
        if ($Codes -contains '0x800f082f') {
            return [pscustomobject]@{ Code = '0x800f082f'; Title = 'A restart is pending (0x800f082f)'; Text = 'Windows has pending servicing operations.'; Steps = @('Restart the PC, then run this tool again.') }
        }
        $code = $null
        if (@($Codes).Count -gt 0) { $code = $Codes[0] }
        return [pscustomobject]@{ Code = $code; Title = 'The language pack could not be installed' + $(if ($code) { " ($code)" } else { '' }); Text = 'See the log for the full error.'; Steps = @($manualUser, $manualIt) }
    }

    function Invoke-LPServicingJob {
        param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][scriptblock]$Script, [object[]]$ArgumentList, $Sync, [switch]$Cancelable)
        $job = Start-Job -ScriptBlock $Script -ArgumentList $ArgumentList
        $start = Get-Date
        $lastText = ''
        $lastLog = Get-Date
        $cancelled = $false
        try {
            while ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') {
                Start-Sleep -Milliseconds 500
                $pct = -1; $status = ''
                $prog = $null
                foreach ($cj in @($job.ChildJobs)) { if ($cj.Progress.Count -gt 0) { $prog = $cj.Progress[$cj.Progress.Count - 1] } }
                if ($prog) { $pct = [int]$prog.PercentComplete; $status = [string]$prog.StatusDescription; if (-not $status) { $status = [string]$prog.Activity } }
                $elapsed = (Get-Date) - $start
                $text = '{0}: {1}{2} (elapsed {3:mm\:ss})' -f $Title, $status, $(if ($pct -ge 0) { " $pct%" } else { '' }), $elapsed
                if ($Sync) { $Sync['Progress'] = @{ Percent = $pct; Text = $text; CanCancel = [bool]$Cancelable } }
                if (($status -and $status -ne $lastText) -or ((Get-Date) - $lastLog).TotalSeconds -ge 30) { Write-LPLog $text -Level Detail; $lastText = $status; $lastLog = Get-Date }
                if ($Cancelable -and $Sync -and $Sync['Cancel']) {
                    Write-LPLog "$Title - cancel requested. Stopping the wait." -Level Warn
                    Stop-Job -Job $job
                    $cancelled = $true
                    break
                }
            }
            if ($cancelled) { return [pscustomobject]@{ Status = 'Cancelled'; Output = $null; ErrorText = $null } }
            $errs = @()
            $out = Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable errs
            $errText = (@($errs | ForEach-Object { $_.ToString(); if ($_.Exception) { $_.Exception.ToString() } }) -join "`n")
            foreach ($cj in @($job.ChildJobs)) { if ($cj.JobStateInfo.Reason) { $errText += "`n" + $cj.JobStateInfo.Reason.ToString() } }
            if ($job.State -eq 'Failed' -or $errs.Count -gt 0) { return [pscustomobject]@{ Status = 'Failed'; Output = $out; ErrorText = $errText } }
            return [pscustomobject]@{ Status = 'Done'; Output = $out; ErrorText = $null }
        }
        finally {
            if ($Sync) { $Sync['Progress'] = @{ Percent = -1; Text = ''; CanCancel = $false } }
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }

    function Install-LPLanguagePack {
        param([Parameter(Mandatory)][string]$Tag, [string]$Method = 'InstallLanguage', [string]$Cab, [bool]$ExcludeFeatures = $true, [int]$Build, $Sync)
        Write-LPLog "Installing display language pack $Tag ($Method)..." -Level Step
        if ($Method -eq 'Source') {
            $r = Invoke-LPServicingJob -Title "Installing $Tag from $Cab" -Sync $Sync -Cancelable -ArgumentList @($Cab) -Script {
                param($cab)
                Add-WindowsPackage -Online -PackagePath $cab -NoRestart -ErrorAction Stop
            }
        }
        else {
            $r = Invoke-LPServicingJob -Title "Installing $Tag (Install-Language)" -Sync $Sync -Cancelable -ArgumentList @($Tag, $ExcludeFeatures) -Script {
                param($tag, $excl)
                Import-Module LanguagePackManagement -ErrorAction Stop
                $p = @{ Language = $tag; ErrorAction = 'Stop' }
                if ($excl -and (Get-Command Install-Language).Parameters.ContainsKey('ExcludeFeatures')) { $p['ExcludeFeatures'] = $true }
                Install-Language @p
            }
        }
        if ($r.Status -eq 'Cancelled') {
            Write-LPLog 'Language pack installation cancelled. Nothing else was changed. Windows may finish the download in the background.' -Level Warn
            return [pscustomobject]@{ Status = 'Cancelled'; Explanation = $null }
        }
        if ($r.Status -eq 'Failed') {
            Write-LPLog ("Install failed: " + $r.ErrorText) -Level Error
            $exp = Get-LPInstallErrorExplanation -Codes (Get-LPHResults $r.ErrorText) -Tag $Tag -Build $Build
            Write-LPLog ($exp.Title + ' - ' + $exp.Text) -Level Error
            foreach ($s in $exp.Steps) { Write-LPLog ('  ' + $s) -Level Error }
            return [pscustomobject]@{ Status = 'Failed'; Explanation = $exp }
        }
        # Install-Language can report a failure in its output object instead of an error record.
        $outText = (@($r.Output) | Out-String)
        $codes = @(Get-LPHResults $outText | Where-Object { $_ -ne '0x00000000' })
        if ($codes.Count -gt 0 -and $outText -match '(?i)fail|error') {
            $exp = Get-LPInstallErrorExplanation -Codes $codes -Tag $Tag -Build $Build
            Write-LPLog ("Install reported: " + $outText.Trim()) -Level Error
            return [pscustomobject]@{ Status = 'Failed'; Explanation = $exp }
        }
        Write-LPLog "Display language pack $Tag installed. $($outText.Trim())" -Level OK
        return [pscustomobject]@{ Status = 'Installed'; Explanation = $null }
    }

    function Uninstall-LPLanguagePacks {
        param([string[]]$Languages, $Sync)
        $failed = @()
        foreach ($l in $Languages) {
            Write-LPLog "Uninstalling language pack $l ..." -Level Step
            $r = Invoke-LPServicingJob -Title "Uninstalling $l" -Sync $Sync -ArgumentList @($l) -Script {
                param($tag)
                Import-Module LanguagePackManagement -ErrorAction Stop
                Uninstall-Language -Language $tag -ErrorAction Stop
            }
            if ($r.Status -eq 'Done') { Write-LPLog "Language pack $l uninstalled." -Level OK }
            else { $failed += $l; Write-LPLog "Could not uninstall $l (Windows may refuse to remove its installation language): $($r.ErrorText)" -Level Warn }
        }
        return $failed
    }

    # --------------------------------------------------------------------------------------------
    # Apply
    # --------------------------------------------------------------------------------------------
    function Copy-LPReferenceToHive {
        param([Parameter(Mandatory)]$Base, [Parameter(Mandatory)][AllowEmptyString()][string]$Root, [Parameter(Mandatory)]$Reference, [bool]$DisableSync)
        foreach ($snap in $Reference) { Set-LPKeyFromSnapshot -Base $Base -Root $Root -Snapshot $snap }
        if ($DisableSync) { Set-LPRegDword -Base $Base -Path (Join-LPRegPath $Root $script:SyncKeySpec.Path) -Name 'Enabled' -Value 0 }
    }

    function Invoke-LPPlan {
        param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Snapshot, $Sync, [int]$TaskTimeoutMinutes = 10)
        $sel = $Plan.Selection
        $results = New-Object System.Collections.Generic.List[object]
        $lines = New-Object System.Collections.Generic.List[object]
        $restartReasons = New-Object System.Collections.Generic.List[string]
        $signOut = New-Object System.Collections.Generic.List[string]
        $nextSignIn = New-Object System.Collections.Generic.List[string]
        $failed = $false
        $blockedByPack = $false
        $cancelled = $false
        # Reference = the language keys of .DEFAULT after the SYSTEM recipe. Created by the 'Reference' step,
        # or on demand when a signed-in user has to be written directly (fallback).
        $ctx = @{ Reference = $null; ReferenceBackup = $null; LazyReference = $false }
        $hku = Get-LPBaseKey 'Users'
        $hklm = Get-LPBaseKey 'LocalMachine'
        $userSpecs = @($script:LanguageKeySet) + @($script:SyncKeySpec)
        $addResult = { param($Step, $Status, $Message) $results.Add([pscustomobject]@{ Kind = $Step.Kind; Title = $Step.Title; Status = $Status; Message = $Message; Step = $Step }) }
        $setProgress = { param($Text) if ($Sync) { $Sync['Progress'] = @{ Percent = -1; Text = $Text; CanCancel = $false } } }

        Write-LPLog ('=== Apply: {0} / {1} / GeoId {2} / {3} -> {4}' -f $sel.DisplayLanguage, $sel.RegionalFormat, $sel.GeoId, (@($sel.Tips) -join ','), (@($Plan.Parts) -join ', ')) -Level Step
        if ($Plan.ReadyPartsOnly -and @($Plan.SkippedParts).Count -gt 0) { Write-LPLog ('PARTIAL apply requested. Skipped (blocked): ' + (@($Plan.SkippedParts) -join ', ')) -Level Warn }
        $backupDir = New-LPBackupSession -Reason 'apply' -Selection $sel

        foreach ($step in $Plan.Steps) {
            if ($cancelled -or $blockedByPack) { & $addResult $step 'Skipped' 'not started'; continue }
            Write-LPLog ("--- " + $step.Title) -Level Step
            & $setProgress $step.Title
            try {
                switch ($step.Kind) {
                    'InstallPack' {
                        $r = Install-LPLanguagePack -Tag $sel.DisplayLanguage -Method $step.Method -Cab $step.Cab -Build $Snapshot.Os.Build -Sync $Sync
                        if ($r.Status -eq 'Installed') { & $addResult $step 'Done' ''; $restartReasons.Add('the display language pack was installed') }
                        elseif ($r.Status -eq 'Cancelled') { $cancelled = $true; & $addResult $step 'Cancelled' 'Cancelled by the user. Nothing else was changed.' }
                        else {
                            $blockedByPack = $true
                            & $addResult $step 'Blocked' ($r.Explanation.Title + '. ' + $r.Explanation.Text)
                            $lines.Add((New-LPLine 'Blocked' $r.Explanation.Title @($r.Explanation.Text, 'Nothing else was changed.') $r.Explanation.Steps))
                        }
                    }
                    'SystemUILanguage' {
                        if (-not (@($script:CurrentBackup.Manifest.Entries | Where-Object { $_.Kind -eq 'Machine' }).Count)) { Backup-LPMachine -Snapshot $Snapshot }
                        try { Set-SystemPreferredUILanguage -Language $sel.DisplayLanguage -ErrorAction Stop; & $addResult $step 'Done' '' }
                        catch { & $addResult $step 'Warning' $_.Exception.Message; Write-LPLog "Set-SystemPreferredUILanguage failed: $($_.Exception.Message). The welcome screen uses the lock-screen account settings written below." -Level Warn }
                    }
                    'RemoteKeyboard' {
                        if (-not (@($script:CurrentBackup.Manifest.Entries | Where-Object { $_.Kind -eq 'Machine' }).Count)) { Backup-LPMachine -Snapshot $Snapshot }
                        Set-LPRegDword -Base $hklm -Path $script:RemoteKbSpec.Path -Name 'IgnoreRemoteKeyboardLayout' -Value 1
                        & $addResult $step 'Done' ''
                    }
                    'SystemLocale' {
                        if (-not (@($script:CurrentBackup.Manifest.Entries | Where-Object { $_.Kind -eq 'Machine' }).Count)) { Backup-LPMachine -Snapshot $Snapshot }
                        if ($Snapshot.Languages.SystemLocale -ne $sel.SystemLocale) {
                            Set-WinSystemLocale -SystemLocale $sel.SystemLocale
                            $restartReasons.Add('the system locale changed')
                        }
                        & $addResult $step 'Done' ''
                    }
                    'Reference' {
                        $r = New-LPReference -Hku $hku -Selection $sel -Snapshot $Snapshot -TaskTimeoutMinutes $TaskTimeoutMinutes
                        $ctx.Reference = $r.Reference
                        $ctx.ReferenceBackup = $r.Backup
                        & $addResult $step 'Done' ''
                        if ($step.KeepLockScreen) { $restartReasons.Add('the lock/welcome screen changed') }
                    }
                    'SystemAccounts' {
                        if (-not $ctx.Reference) { throw 'No reference available.' }
                        foreach ($sid in 'S-1-5-19', 'S-1-5-20') {
                            try {
                                if (-not (Test-LPRegKey $hku $sid)) { Write-LPLog "HKU\$sid is not loaded; skipped." -Level Warn; continue }
                                $null = Backup-LPHive -Base $hku -Root $sid -Label "SystemAccount_$sid" -TargetId 'lockscreen' -Sid $sid -Specs $script:LanguageKeySet
                                Copy-LPReferenceToHive -Base $hku -Root $sid -Reference $ctx.Reference -DisableSync $false
                                Write-LPLog "Copied to HKU\$sid" -Level OK
                            }
                            catch { Write-LPLog "Could not write HKU\$sid : $($_.Exception.Message)" -Level Warn }
                        }
                        & $addResult $step 'Done' ''
                    }
                    'NewUsers' {
                        if (-not $ctx.Reference) { throw 'No reference available.' }
                        $null = Use-LPHive -HivePath $step.HivePath -Label 'DefaultUser' -Action {
                            param($b, $r)
                            $null = Backup-LPHive -Base $b -Root $r -Label 'DefaultProfile' -TargetId 'newusers' -HivePath $step.HivePath -Specs $userSpecs
                            Copy-LPReferenceToHive -Base $b -Root $r -Reference $ctx.Reference -DisableSync ([bool]$sel.DisableSync)
                        }
                        & $addResult $step 'Done' ''
                    }
                    'User' {
                        $signedNow = Get-LPSignedInUsers
                        if ($signedNow.ContainsKey($step.Sid)) {
                            $null = Backup-LPHive -Base $hku -Root $step.Sid -Label $step.Name -TargetId $step.Part -Sid $step.Sid -HivePath $step.HivePath -Specs $userSpecs
                            $w = Invoke-LPWorkerTask -Sid $step.Sid -Label $step.Name -Selection $sel -TimeoutMinutes $TaskTimeoutMinutes
                            foreach ($wn in @($w.Warnings)) { if ($wn) { Write-LPLog $wn -Level Warn } }
                            if ($w.Success) {
                                $signOut.Add($step.Name)
                                & $addResult $step 'Done' 'applied in the user''s session'
                            }
                            else {
                                # Fallback: write the verified reference straight into the user's loaded hive.
                                # Same method as for users who are not signed in; active after sign-out/sign-in.
                                Write-LPLog "In-session step for $($step.Name) failed: $($w.Error)" -Level Warn
                                Write-LPLog "Writing the profile directly into $($step.Name)'s registry instead (active after sign-out and sign-in)." -Level Warn
                                if (-not $ctx.Reference) {
                                    $r = New-LPReference -Hku $hku -Selection $sel -Snapshot $Snapshot -TaskTimeoutMinutes $TaskTimeoutMinutes
                                    $ctx.Reference = $r.Reference
                                    $ctx.ReferenceBackup = $r.Backup
                                    $ctx.LazyReference = $true
                                }
                                Copy-LPReferenceToHive -Base $hku -Root $step.Sid -Reference $ctx.Reference -DisableSync ([bool]$sel.DisableSync)
                                $signOut.Add($step.Name)
                                & $addResult $step 'Warning' ("written directly into the profile - active after sign-out and sign-in. The in-session step did not run: " + $w.Error)
                            }
                        }
                        else {
                            if (-not $ctx.Reference) { throw "$($step.Name) is no longer signed in, and no reference was prepared for profiles that are not signed in. Run the tool again." }
                            try {
                                $null = Use-LPHive -Sid $step.Sid -HivePath $step.HivePath -Label $step.Sid -Action {
                                    param($b, $r)
                                    $null = Backup-LPHive -Base $b -Root $r -Label $step.Name -TargetId $step.Part -Sid $step.Sid -HivePath $step.HivePath -Specs $userSpecs
                                    Copy-LPReferenceToHive -Base $b -Root $r -Reference $ctx.Reference -DisableSync ([bool]$sel.DisableSync)
                                }
                                $nextSignIn.Add($step.Name)
                                & $addResult $step 'Done' 'written into the profile'
                            }
                            catch {
                                if ($_.Exception.Message -match 'Could not load|not found') {
                                    Write-LPLog "Skipped $($step.Name): $($_.Exception.Message)" -Level Warn
                                    & $addResult $step 'Skipped' $_.Exception.Message
                                }
                                else { throw }
                            }
                        }
                    }
                    'RestoreReference' {
                        if ($ctx.ReferenceBackup) {
                            foreach ($snap in $ctx.ReferenceBackup) { Set-LPKeyFromSnapshot -Base $hku -Root '.DEFAULT' -Snapshot $snap }
                            Write-LPLog 'Lock screen restored to its previous state (it was only used as reference).' -Level OK
                        }
                        & $addResult $step 'Done' ''
                    }
                    'Uninstall' {
                        $f = @(Uninstall-LPLanguagePacks -Languages $step.Languages -Sync $Sync)
                        if ($f.Count -gt 0) { & $addResult $step 'Warning' ('Not removed: ' + ($f -join ', ')) } else { & $addResult $step 'Done' '' }
                        if ($f.Count -lt @($step.Languages).Count) { $restartReasons.Add('language packs were removed') }
                    }
                    default { throw "Unknown step $($step.Kind)" }
                }
            }
            catch {
                $failed = $true
                Write-LPLog ("FAILED: {0}: {1}" -f $step.Title, $_.Exception.Message) -Level Error
                & $addResult $step 'Failed' $_.Exception.Message
                if ($step.Kind -eq 'Reference') {
                    # Without a reference nothing can be copied (New-LPReference already put the lock screen back). Stop.
                    $blockedByPack = $true
                }
            }
        }

        # A reference created on demand for a fallback is only temporary unless the lock screen is a target.
        if ($ctx.LazyReference -and -not (@($Plan.Parts) -contains 'lockscreen') -and $ctx.ReferenceBackup) {
            try {
                foreach ($snap in $ctx.ReferenceBackup) { Set-LPKeyFromSnapshot -Base $hku -Root '.DEFAULT' -Snapshot $snap }
                Write-LPLog 'Lock screen restored to its previous state (it was only used as reference).' -Level OK
            }
            catch { Write-LPLog "Could not restore the lock screen: $($_.Exception.Message)" -Level Error; $failed = $true }
        }

        # Verify what was written (fresh read).
        if (-not $cancelled -and -not $blockedByPack) {
            Write-LPLog 'Verifying...' -Level Step
            $doneSteps = @($results | Where-Object { $_.Status -eq 'Done' -or ($_.Status -eq 'Warning' -and $_.Kind -eq 'User') } | ForEach-Object { $_.Step })
            foreach ($step in @($doneSteps | Where-Object { $_.Kind -eq 'User' -or $_.Kind -eq 'NewUsers' -or ($_.Kind -eq 'Reference' -and $_.KeepLockScreen) })) {
                try {
                    $st = $null
                    if ($step.Kind -eq 'Reference') { $st = Get-LPHiveState -Base $hku -Root '.DEFAULT' -Layouts $Snapshot.KeyboardLayouts; $kind = 'LockScreen'; $name = 'Lock screen' }
                    elseif ($step.Kind -eq 'NewUsers') { $st = Use-LPHive -HivePath $step.HivePath -Label 'DefaultUser' -Action { param($b, $r) Get-LPHiveState -Base $b -Root $r -Layouts $Snapshot.KeyboardLayouts }; $kind = 'NewUsers'; $name = 'New users' }
                    else { $st = Use-LPHive -Sid $step.Sid -HivePath $step.HivePath -Label $step.Sid -Action { param($b, $r) Get-LPHiveState -Base $b -Root $r -Layouts $Snapshot.KeyboardLayouts }; $kind = 'User'; $name = $step.Name }
                    $iss = @(Test-LPStateCompliance -State $st -Selection $sel -Kind $kind -SystemUILanguage $sel.DisplayLanguage)
                    if ($iss.Count -eq 0) { Write-LPLog "$name : verified" -Level OK }
                    else { Write-LPLog ("$name : differs after apply: " + ($iss -join '; ')) -Level Warn }
                }
                catch { Write-LPLog "Could not verify $($step.Title): $($_.Exception.Message)" -Level Warn }
            }
        }

        $pr = Get-LPPendingReboot
        if ($pr.Pending -and -not $restartReasons.Count) { $restartReasons.Add('Windows reports a pending restart') }
        $restartNeeded = ($restartReasons.Count -gt 0) -and -not $cancelled -and -not $blockedByPack
        $partial = ($Plan.ReadyPartsOnly -and @($Plan.SkippedParts).Count -gt 0)
        $done = @($results | Where-Object { $_.Status -eq 'Done' -or $_.Status -eq 'Warning' }).Count

        $exit = $script:ExitCodes.Done
        $outcome = 'Done'
        if ($cancelled) { $exit = $script:ExitCodes.Blocked; $outcome = 'Cancelled' }
        elseif ($blockedByPack -and -not $failed) { $exit = $script:ExitCodes.Blocked; $outcome = 'Blocked' }
        elseif ($failed) { $exit = $script:ExitCodes.Error; $outcome = 'Error' }
        elseif ($partial) { $exit = $script:ExitCodes.Partial; $outcome = 'Partial' }
        elseif ($restartNeeded) { $exit = $script:ExitCodes.RestartNeeded; $outcome = 'DoneRestart' }

        $summary = New-Object System.Collections.Generic.List[object]
        $summary.Add((New-LPLine 'Heading1' 'Result'))
        switch ($outcome) {
            'Done' { $summary.Add((New-LPLine 'OK' 'Done.')) }
            'DoneRestart' { $summary.Add((New-LPLine 'OK' 'Done - a restart is needed.')) }
            'Partial' { $summary.Add((New-LPLine 'Warn' 'Partially applied. The blocked parts were NOT changed:' @($Plan.SkippedParts | ForEach-Object { $t = Find-LPTarget $Snapshot $_; if ($t) { $t.Name } else { $_ } }))) }
            'Cancelled' { $summary.Add((New-LPLine 'Warn' 'Cancelled while installing the language pack. Nothing was changed.')) }
            'Blocked' { $summary.Add((New-LPLine 'Blocked' 'Stopped: a required prerequisite could not be added. Nothing was changed.')) }
            'Error' {
                if ($done -gt 0) { $summary.Add((New-LPLine 'Blocked' 'Error - the profile was applied only partly. See below and the log; use Restore to go back.')) }
                else { $summary.Add((New-LPLine 'Blocked' 'Error - see the log.')) }
            }
        }
        foreach ($l in $lines) { $summary.Add($l) }
        foreach ($r in $results) {
            $lvl = switch ($r.Status) { 'Done' { 'OK' } 'Warning' { 'Warn' } 'Skipped' { 'Info' } 'Failed' { 'Blocked' } 'Blocked' { 'Blocked' } default { 'Info' } }
            $summary.Add((New-LPLine $lvl ('{0}: {1}' -f $r.Title, $r.Status) @($r.Message)))
        }
        if (-not $cancelled -and -not $blockedByPack) {
            if ($signOut.Count -gt 0) { $summary.Add((New-LPLine 'Info' ('Sign out and in again (display language): ' + ($signOut -join ', ')))) }
            if ($nextSignIn.Count -gt 0) { $summary.Add((New-LPLine 'Info' ('Active at their next sign-in: ' + ($nextSignIn -join ', ')))) }
            if ($restartNeeded) { $summary.Add((New-LPLine 'Info' ('Restart needed: ' + (@($restartReasons | Select-Object -Unique) -join ', ')))) }
        }
        $summary.Add((New-LPLine 'Info' "Backup: $backupDir"))
        $summary.Add((New-LPLine 'Info' "Log: $script:LogFile"))
        Write-LPLog ("=== Result: {0} (exit code {1})" -f $outcome, $exit) -Level Step
        foreach ($l in $summary) { if ($l.Level -ne 'Heading1') { Write-LPLog ($l.Text + $(if (@($l.Detail).Count) { ' - ' + (@($l.Detail) -join ' / ') } else { '' })) -Level Info } }
        $script:CurrentBackup = $null
        return [pscustomobject]@{
            Outcome       = $outcome
            ExitCode      = $exit
            RestartNeeded = $restartNeeded
            SignOut       = $signOut.ToArray()
            NextSignIn    = $nextSignIn.ToArray()
            Steps         = $results.ToArray()
            Lines         = $summary.ToArray()
            BackupPath    = $backupDir
            LogFile       = $script:LogFile
        }
    }

    # --------------------------------------------------------------------------------------------
    # Restore
    # --------------------------------------------------------------------------------------------
    function Restore-LPBackup {
        param([Parameter(Mandatory)][string]$Path)
        if ($Path -eq 'Latest') {
            $b = @(Get-LPBackups | Where-Object { $_.Reason -eq 'apply' })
            if ($b.Count -eq 0) { throw 'No backup found.' }
            $Path = $b[0].Path
        }
        $mf = Join-Path $Path 'manifest.json'
        if (-not (Test-Path -LiteralPath $mf)) { throw "No manifest.json in $Path" }
        $m = [IO.File]::ReadAllText($mf) | ConvertFrom-Json
        Write-LPLog "=== Restore from $Path (created $($m.Created) by $($m.RunBy))" -Level Step
        $null = New-LPBackupSession -Reason 'before-restore'
        $hku = Get-LPBaseKey 'Users'
        $hklm = Get-LPBaseKey 'LocalMachine'
        $lines = New-Object System.Collections.Generic.List[object]
        $lines.Add((New-LPLine 'Heading1' 'Restore'))
        $errors = 0
        $restart = $false
        $entries = @($m.Entries)
        [array]::Reverse($entries)   # earliest backup of a key wins
        foreach ($e in $entries) {
            try {
                if ($e.Kind -eq 'Machine') {
                    $null = Backup-LPMachineCurrent
                    foreach ($s in @($e.Snapshots)) { Set-LPKeyFromSnapshot -Base $hklm -Root '' -Snapshot $s }
                    if ($e.SystemPreferredUILanguage -and (Test-LPCommand 'Set-SystemPreferredUILanguage')) {
                        try { Set-SystemPreferredUILanguage -Language $e.SystemPreferredUILanguage -ErrorAction Stop } catch { Write-LPLog "Set-SystemPreferredUILanguage: $($_.Exception.Message)" -Level Warn }
                    }
                    if ($e.SystemLocale) {
                        $cur = $null; try { $cur = (Get-WinSystemLocale).Name } catch { }
                        if ($cur -and $cur -ne $e.SystemLocale) { Set-WinSystemLocale -SystemLocale $e.SystemLocale; $restart = $true }
                    }
                    $lines.Add((New-LPLine 'OK' 'This PC: machine settings restored'))
                    $restart = $true
                    continue
                }
                $sid = [string]$e.Sid
                $action = {
                    param($b, $r)
                    $null = Backup-LPHive -Base $b -Root $r -Label ([string]$e.Label) -TargetId ([string]$e.TargetId) -Sid $sid -HivePath ([string]$e.HivePath) -Specs @($e.Snapshots | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Path = $_.Path; Mode = $_.Mode; Names = $_.Names } })
                    foreach ($s in @($e.Snapshots)) { Set-LPKeyFromSnapshot -Base $b -Root $r -Snapshot $s }
                }
                if ($sid -eq 'S-1-5-18') { & $action $hku '.DEFAULT'; $restart = $true }
                elseif ($sid -eq 'S-1-5-19' -or $sid -eq 'S-1-5-20') { & $action $hku $sid }
                elseif ($sid) { $null = Use-LPHive -Sid $sid -HivePath ([string]$e.HivePath) -Label $sid -Action $action }
                else { $null = Use-LPHive -HivePath ([string]$e.HivePath) -Label 'DefaultUser' -Action $action }
                $lines.Add((New-LPLine 'OK' "$($e.Label): restored"))
            }
            catch {
                $errors++
                $lines.Add((New-LPLine 'Blocked' "$($e.Label): $($_.Exception.Message)"))
                Write-LPLog "Restore of $($e.Label) failed: $($_.Exception.Message)" -Level Error
            }
        }
        $lines.Add((New-LPLine 'Info' 'Installed or removed language packs were NOT rolled back.'))
        $lines.Add((New-LPLine 'Info' 'Signed-in users must sign out and in again; restart the PC for the lock screen.'))
        $lines.Add((New-LPLine 'Info' "Log: $script:LogFile"))
        $script:CurrentBackup = $null
        $exit = $script:ExitCodes.Done
        if ($errors -gt 0) { $exit = $script:ExitCodes.Error } elseif ($restart) { $exit = $script:ExitCodes.RestartNeeded }
        Write-LPLog ("=== Restore finished with {0} error(s)" -f $errors) -Level Step
        return [pscustomobject]@{ ExitCode = $exit; Lines = $lines.ToArray(); Errors = $errors }
    }

    function Backup-LPMachineCurrent {
        $hklm = Get-LPBaseKey 'LocalMachine'
        $snap = Get-LPKeySnapshot -Base $hklm -Root '' -Spec $script:RemoteKbSpec
        $sysUi = $null
        if (Test-LPCommand 'Get-SystemPreferredUILanguage') { try { $sysUi = [string](Get-SystemPreferredUILanguage) } catch { } }
        $loc = $null; try { $loc = (Get-WinSystemLocale).Name } catch { }
        $entry = [pscustomobject]@{ Kind = 'Machine'; Snapshots = @($snap); SystemPreferredUILanguage = $sysUi; SystemLocale = $loc; RegFiles = @() }
        $script:CurrentBackup.Manifest.Entries = @($script:CurrentBackup.Manifest.Entries) + @($entry)
        Save-LPBackupManifest
    }

    Export-ModuleMember -Function *
}

# ================================================================================================
# 2. WPF FRONT-END (uses only the engine's exported functions)
# ================================================================================================
$LPXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Language Profile" Width="1220" Height="880" MinWidth="1000" MinHeight="680"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13" Background="#FFFFFF">
  <Window.Resources>
    <Style TargetType="GroupBox">
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Setter Property="Padding" Value="8"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="MinWidth" Value="80"/>
    </Style>
  </Window.Resources>
  <DockPanel>
    <Border DockPanel.Dock="Top" Background="#1F3A5F" Padding="16,10">
      <StackPanel>
        <TextBlock Text="Language Profile" Foreground="White" FontSize="20" FontWeight="SemiBold"/>
        <TextBlock x:Name="TxtContext" Foreground="#D6E4F5" Text="Starting..." TextWrapping="Wrap"/>
      </StackPanel>
    </Border>
    <Border DockPanel.Dock="Top" Background="#F2F5F9" BorderBrush="#D5DDE8" BorderThickness="0,0,0,1" Padding="16,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="280"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="Preset" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,10,0"/>
        <ComboBox Grid.Column="1" x:Name="CmbPreset" VerticalAlignment="Center"/>
        <TextBlock Grid.Column="2" x:Name="TxtPresetInfo" VerticalAlignment="Center" Margin="12,0" Foreground="#4A5A6A" TextWrapping="Wrap"/>
        <Button Grid.Column="3" x:Name="BtnApplyStandard" Content="Apply standard setup" FontSize="15" FontWeight="SemiBold" Padding="22,9" Margin="0" Background="#2E7D32" Foreground="White" BorderBrush="#1B5E20" IsEnabled="False"/>
      </Grid>
    </Border>
    <StatusBar DockPanel.Dock="Bottom">
      <StatusBarItem><TextBlock x:Name="TxtStatusBar" Text="Starting..."/></StatusBarItem>
    </StatusBar>
    <TabControl x:Name="Tabs" Margin="10">
      <TabItem Header="  Configure  " x:Name="TabConfigure">
        <Grid Margin="6">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="14"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <GroupBox Header="Display language">
                <StackPanel>
                  <ComboBox x:Name="CmbDisplay" MaxDropDownHeight="420"/>
                  <TextBlock x:Name="TxtDisplayNote" Margin="0,6,0,0" Foreground="#4A5A6A" TextWrapping="Wrap"/>
                </StackPanel>
              </GroupBox>
              <GroupBox Header="Regional format">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Grid.Column="0" Text="Search" VerticalAlignment="Center" Margin="0,0,8,6"/>
                  <TextBox Grid.Row="0" Grid.Column="1" x:Name="TxtFormatFilter" Margin="0,0,0,6" ToolTip="Type part of a name or code, e.g. swi or de-"/>
                  <TextBlock Grid.Row="1" Grid.Column="0" Text="Format" VerticalAlignment="Center" Margin="0,0,8,6"/>
                  <ComboBox Grid.Row="1" Grid.Column="1" x:Name="CmbFormat" Margin="0,0,0,6" MaxDropDownHeight="420"/>
                  <TextBlock Grid.Row="2" Grid.Column="1" x:Name="TxtFormatSelected" Margin="0,0,0,6" Foreground="#4A5A6A"/>
                  <TextBlock Grid.Row="3" Grid.Column="0" Text="Country/region" VerticalAlignment="Center" Margin="0,0,8,0"/>
                  <ComboBox Grid.Row="3" Grid.Column="1" x:Name="CmbGeo" MaxDropDownHeight="420"/>
                </Grid>
              </GroupBox>
              <GroupBox Header="Keyboard layouts (the first one is the default)">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <TextBox Grid.Row="0" Grid.Column="0" x:Name="TxtKbFilter" Margin="0,0,0,4" ToolTip="Search layouts by name or ID"/>
                  <TextBlock Grid.Row="0" Grid.Column="2" Text="Selected" FontWeight="SemiBold" Margin="0,0,0,4" VerticalAlignment="Bottom"/>
                  <ListBox Grid.Row="1" Grid.Column="0" x:Name="LstKbAvailable" Height="200" SelectionMode="Extended"/>
                  <StackPanel Grid.Row="1" Grid.Column="1" VerticalAlignment="Center" Margin="6,0">
                    <Button x:Name="BtnKbAdd" Content="Add &gt;" Margin="0,0,0,6"/>
                    <Button x:Name="BtnKbRemove" Content="&lt; Remove" Margin="0,0,0,6"/>
                    <Button x:Name="BtnKbUp" Content="Up" Margin="0,0,0,6"/>
                    <Button x:Name="BtnKbDown" Content="Down" Margin="0"/>
                  </StackPanel>
                  <ListBox Grid.Row="1" Grid.Column="2" x:Name="LstKbSelected" Height="200"/>
                  <TextBlock Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="3" x:Name="TxtKbNote" Margin="0,6,0,0" Foreground="#4A5A6A" TextWrapping="Wrap"/>
                </Grid>
              </GroupBox>
            </StackPanel>
          </ScrollViewer>
          <ScrollViewer Grid.Column="2" VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <GroupBox Header="Apply to">
                <StackPanel>
                  <StackPanel x:Name="PnlTargets">
                    <TextBlock Text="Scanning user profiles..." Foreground="#4A5A6A"/>
                  </StackPanel>
                  <Button x:Name="BtnRescan" Content="Re-scan PC" HorizontalAlignment="Left" Margin="0,8,0,0" IsEnabled="False"/>
                </StackPanel>
              </GroupBox>
              <GroupBox Header="Options">
                <StackPanel>
                  <CheckBox x:Name="ChkSync" IsChecked="True" Margin="0,0,0,4"><TextBlock Text="Disable language sync for the targets" TextWrapping="Wrap"/></CheckBox>
                  <CheckBox x:Name="ChkRdp" IsChecked="True" Margin="0,0,0,4"><TextBlock Text="Block Remote Desktop keyboard injection (IgnoreRemoteKeyboardLayout = 1)" TextWrapping="Wrap"/></CheckBox>
                  <CheckBox x:Name="ChkSysLocale" Margin="0"><TextBlock x:Name="TxtSysLocaleLabel" Text="Set the system locale for non-Unicode programs" TextWrapping="Wrap"/></CheckBox>
                  <TextBlock Margin="20,0,0,6" Foreground="#B26A00" TextWrapping="Wrap" Text="Needs a restart. Older (non-Unicode) programs may show garbled text if they expect another code page."/>
                  <CheckBox x:Name="ChkUninstall" Margin="0"><TextBlock Text="Uninstall other language packs" TextWrapping="Wrap"/></CheckBox>
                  <TextBlock Margin="20,0,0,6" Foreground="#C62828" TextWrapping="Wrap" Text="WARNING: removes every other installed display language pack (translated Windows interface) from this PC - for ALL users, also those not selected. The display language being applied is never removed. Needs a restart. Restore does not bring removed packs back. Not needed to remove languages from the lists - Apply does that anyway."/>
                  <TextBlock Text="Language pack source folder (optional, for WSUS or offline PCs):" Margin="0,4,0,2"/>
                  <DockPanel>
                    <Button DockPanel.Dock="Right" x:Name="BtnBrowseSource" Content="Browse..." Margin="6,0,0,0"/>
                    <TextBox x:Name="TxtSource" ToolTip="Folder containing Microsoft-Windows-Client-Language-Pack_x64_xx-xx.cab from the Languages and Optional Features ISO"/>
                  </DockPanel>
                </StackPanel>
              </GroupBox>
              <GroupBox Header="Readiness">
                <StackPanel>
                  <TextBlock x:Name="TxtReadySummary" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,0,0,6" Text="Scanning this PC..."/>
                  <StackPanel x:Name="PnlReadiness"/>
                  <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
                    <Button x:Name="BtnPreview" Content="Preview changes..." FontWeight="SemiBold" IsEnabled="False"/>
                  </StackPanel>
                </StackPanel>
              </GroupBox>
            </StackPanel>
          </ScrollViewer>
        </Grid>
      </TabItem>
      <TabItem Header="  Status  " x:Name="TabStatus">
        <DockPanel Margin="6">
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
            <Button x:Name="BtnStatusRefresh" Content="Refresh" IsEnabled="False"/>
            <TextBlock VerticalAlignment="Center" Foreground="#4A5A6A" Text="Read-only: the current state of every profile on this PC, hidden layouts and re-add risks."/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="PnlStatus" Margin="0,0,10,0"/></ScrollViewer>
        </DockPanel>
      </TabItem>
      <TabItem Header="  Preview and apply  " x:Name="TabApply">
        <Grid Margin="6">
          <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="220"/>
          </Grid.RowDefinitions>
          <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="PnlPreview" Margin="0,0,10,0"><TextBlock Text="Click 'Preview changes...' on the Configure tab." Foreground="#4A5A6A"/></StackPanel></ScrollViewer>
          <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,8,0,8">
            <Button x:Name="BtnApply" Content="Apply" FontWeight="SemiBold" Background="#1565C0" Foreground="White" IsEnabled="False"/>
            <Button x:Name="BtnApplyReady" Content="Apply ONLY the parts that are ready" Visibility="Collapsed" Background="#E65100" Foreground="White"/>
            <Button x:Name="BtnCancel" Content="Cancel download" IsEnabled="False"/>
            <Button x:Name="BtnOpenLog" Content="Open log"/>
          </StackPanel>
          <StackPanel Grid.Row="2" Margin="0,0,0,6">
            <ProgressBar x:Name="PrgApply" Height="16" Minimum="0" Maximum="100"/>
            <TextBlock x:Name="TxtProgress" Margin="0,4,0,0" Foreground="#4A5A6A" TextWrapping="Wrap"/>
          </StackPanel>
          <TextBox Grid.Row="3" x:Name="TxtLog" IsReadOnly="True" FontFamily="Consolas" FontSize="12" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
        </Grid>
      </TabItem>
      <TabItem Header="  Restore  " x:Name="TabRestore">
        <DockPanel Margin="6">
          <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" Margin="0,0,0,8" Text="Every Apply first backs up all registry keys it changes. Restore writes those keys back exactly as they were. Installed or removed language packs are NOT rolled back."/>
          <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,8,0,0">
            <Button x:Name="BtnRestore" Content="Restore selected backup" IsEnabled="False"/>
            <Button x:Name="BtnRestoreRefresh" Content="Refresh list"/>
            <TextBlock x:Name="TxtBackupRoot" VerticalAlignment="Center" Foreground="#4A5A6A"/>
          </StackPanel>
          <ListBox x:Name="LstBackups"/>
        </DockPanel>
      </TabItem>
    </TabControl>
  </DockPanel>
</Window>
'@

# Runs inside a background runspace: loads the engine and runs one unit of work.
$LPBackgroundBootstrap = @'
param($EngineText, $Sync, $WorkText, $WorkArgs, $ScriptRoot, $LogFile)
$ErrorActionPreference = 'Stop'
New-Module -Name LanguageProfileEngine -ScriptBlock ([scriptblock]::Create($EngineText)) | Import-Module -Force -DisableNameChecking
$null = Initialize-LPEngine -ScriptRoot $ScriptRoot -LogQueue $Sync['Log'] -LogFile $LogFile
$work = [scriptblock]::Create($WorkText)
& $work $Sync $WorkArgs
'@

$script:LPBadges = @{
    OK      = @('OK', '#2E7D32')
    Auto    = @('AUTOMATIC', '#1565C0')
    Blocked = @('BLOCKED', '#C62828')
    Warn    = @('WARNING', '#E65100')
    Risk    = @('RE-ADD RISK', '#AD1457')
    Info    = @('INFO', '#607D8B')
    Set     = @('SET', '#1565C0')
    Remove  = @('REMOVE', '#B71C1C')
    Install = @('INSTALL', '#00838F')
    Keep    = @('UNCHANGED', '#9E9E9E')
}

function Get-LPBrush {
    param([string]$Hex)
    $b = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex)
    $b.Freeze()
    return $b
}

function New-LPTextBlock {
    param([string]$Text, [double]$Size = 13, [string]$Color, [switch]$Bold, [switch]$Wrap)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontSize = $Size
    if ($Color) { $tb.Foreground = Get-LPBrush $Color }
    if ($Bold) { $tb.FontWeight = [System.Windows.FontWeights]::SemiBold }
    if ($Wrap) { $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap }
    return $tb
}

function Show-LPReportPanel {
    param($Panel, $Lines)
    $Panel.Children.Clear()
    foreach ($l in @($Lines)) {
        if ($null -eq $l) { continue }
        if ($l.Level -eq 'Heading1' -or $l.Level -eq 'Heading2') {
            $size = 13; $top = 8
            if ($l.Level -eq 'Heading1') { $size = 15; $top = 14 }
            $tb = New-LPTextBlock -Text $l.Text -Size $size -Color '#1F3A5F' -Bold -Wrap
            $tb.Margin = New-Object System.Windows.Thickness(0, $top, 0, 3)
            [void]$Panel.Children.Add($tb)
            continue
        }
        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = New-Object System.Windows.Thickness(0, 2, 0, 2)
        $c0 = New-Object System.Windows.Controls.ColumnDefinition
        $c0.Width = New-Object System.Windows.GridLength(108)
        $c1 = New-Object System.Windows.Controls.ColumnDefinition
        $c1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        [void]$grid.ColumnDefinitions.Add($c0)
        [void]$grid.ColumnDefinitions.Add($c1)
        $badge = $script:LPBadges[$l.Level]
        if ($badge) {
            $b = New-Object System.Windows.Controls.Border
            $b.Background = Get-LPBrush $badge[1]
            $b.CornerRadius = New-Object System.Windows.CornerRadius(3)
            $b.Padding = New-Object System.Windows.Thickness(4, 1, 4, 1)
            $b.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
            $b.Margin = New-Object System.Windows.Thickness(0, 1, 6, 0)
            $bt = New-LPTextBlock -Text $badge[0] -Size 10.5 -Color '#FFFFFF' -Bold
            $bt.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
            $b.Child = $bt
            [System.Windows.Controls.Grid]::SetColumn($b, 0)
            [void]$grid.Children.Add($b)
        }
        $sp = New-Object System.Windows.Controls.StackPanel
        [System.Windows.Controls.Grid]::SetColumn($sp, 1)
        if (-not $badge) { [System.Windows.Controls.Grid]::SetColumn($sp, 0); [System.Windows.Controls.Grid]::SetColumnSpan($sp, 2) }
        $main = New-LPTextBlock -Text $l.Text -Wrap
        if ($l.Level -eq 'Text') { $main.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas'); $main.FontSize = 12.5 }
        [void]$sp.Children.Add($main)
        foreach ($d in @($l.Detail)) { if ($d) { $t = New-LPTextBlock -Text $d -Size 12 -Color '#55606B' -Wrap; [void]$sp.Children.Add($t) } }
        foreach ($s in @($l.Steps)) { if ($s) { $t = New-LPTextBlock -Text ('-> ' + $s) -Size 12 -Color '#263238' -Wrap; $t.Margin = New-Object System.Windows.Thickness(8, 1, 0, 0); [void]$sp.Children.Add($t) } }
        [void]$grid.Children.Add($sp)
        [void]$Panel.Children.Add($grid)
    }
}

function Select-LPItemByTag {
    param($Control, [string]$Tag)
    foreach ($i in $Control.Items) { if ([string]$i.Tag -eq $Tag) { $Control.SelectedItem = $i; return $true } }
    return $false
}

function New-LPListItem {
    param([string]$Type = 'ComboBoxItem', [string]$Text, [string]$Tag, [switch]$Disabled)
    $i = New-Object ("System.Windows.Controls.$Type")
    $i.Content = $Text
    $i.Tag = $Tag
    if ($Disabled) { $i.IsEnabled = $false }
    return $i
}

function Update-LPUiDisplayList {
    $g = $script:G
    $prevSuppress = $g.Suppress
    $g.Suppress = $true
    try {
        $g.CmbDisplay.Items.Clear()
        $snap = $g.Snapshot
        $tags = @{}
        $entries = New-Object System.Collections.Generic.List[object]
        foreach ($c in (Get-LPDisplayLanguageCatalog)) { $entries.Add($c); $tags[$c.Tag] = $true }
        if ($snap) {
            foreach ($t in @($snap.Languages.Installed)) {
                if (-not $tags.ContainsKey($t)) {
                    $ci = Get-LPCultureInfo $t
                    $n = $t; if ($ci) { $n = $ci.EnglishName }
                    $entries.Add([pscustomobject]@{ Tag = $t; Name = $n; Type = 'Installed'; Base = @() })
                }
            }
        }
        foreach ($e in @($entries | Sort-Object Name)) {
            $mark = 'checking...'
            if ($snap) {
                $isWin11 = ($snap.Os -and $snap.Os.IsWin11)
                if (@($snap.Languages.Installed) -contains $e.Tag) {
                    $mark = 'installed'
                    if (-not (@($snap.Languages.FullPack) -contains $e.Tag)) { $mark = 'installed (LXP only)' }
                }
                elseif ($snap.Capabilities.InstallLanguage -and ($e.Type -eq 'LP' -or ($e.Type -eq 'LIPCAB' -and $isWin11))) { $mark = 'will be installed' }
                else { $mark = 'not installed - install manually' }
            }
            [void]$g.CmbDisplay.Items.Add((New-LPListItem -Text ('{0}  -  {1}     [{2}]' -f $e.Name, $e.Tag, $mark) -Tag $e.Tag))
        }
        if ($g.Sel.Display) {
            if (-not (Select-LPItemByTag $g.CmbDisplay $g.Sel.Display)) {
                $i = New-LPListItem -Text ('{0}     [unknown]' -f $g.Sel.Display) -Tag $g.Sel.Display
                [void]$g.CmbDisplay.Items.Insert(0, $i)
                $g.CmbDisplay.SelectedItem = $i
            }
        }
    }
    finally { $g.Suppress = $prevSuppress }
}

function Update-LPUiFormatList {
    $g = $script:G
    $prevSuppress = $g.Suppress
    $g.Suppress = $true
    try {
        $f = $g.TxtFormatFilter.Text.Trim()
        $g.CmbFormat.Items.Clear()
        $match = { param($x) (-not $f) -or $x.Name.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $x.EnglishName.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
        $favs = @($g.Formats | Where-Object { $_.Favorite -and (& $match $_) })
        $rest = @($g.Formats | Where-Object { -not $_.Favorite -and (& $match $_) })
        foreach ($x in $favs) { [void]$g.CmbFormat.Items.Add((New-LPListItem -Text ('* ' + $x.Display) -Tag $x.Name)) }
        if ($favs.Count -gt 0 -and $rest.Count -gt 0) { [void]$g.CmbFormat.Items.Add((New-LPListItem -Text '----------  all formats  ----------' -Tag '' -Disabled)) }
        foreach ($x in $rest) { [void]$g.CmbFormat.Items.Add((New-LPListItem -Text $x.Display -Tag $x.Name)) }
        if ($g.Sel.Format) { [void](Select-LPItemByTag $g.CmbFormat $g.Sel.Format) }
        $ci = Get-LPCultureInfo $g.Sel.Format
        $g.TxtFormatSelected.Text = 'Selected: ' + $(if ($ci) { '{0} ({1})  -  e.g. {2}' -f $ci.EnglishName, $ci.Name, (Get-Date).ToString('d', $ci) + ' ' + (1234567.89).ToString('N2', $ci) } else { $g.Sel.Format })
    }
    finally { $g.Suppress = $prevSuppress }
}

function Update-LPUiGeoList {
    $g = $script:G
    $prevSuppress = $g.Suppress
    $g.Suppress = $true
    try {
        if ($g.CmbGeo.Items.Count -eq 0) {
            foreach ($x in $g.Geos) { [void]$g.CmbGeo.Items.Add((New-LPListItem -Text $x.Display -Tag ([string]$x.GeoId))) }
        }
        if ($g.Sel.GeoId -gt 0) {
            if (-not (Select-LPItemByTag $g.CmbGeo ([string]$g.Sel.GeoId))) {
                $i = New-LPListItem -Text ('GeoId {0}' -f $g.Sel.GeoId) -Tag ([string]$g.Sel.GeoId)
                [void]$g.CmbGeo.Items.Insert(0, $i)
                $g.CmbGeo.SelectedItem = $i
            }
        }
    }
    finally { $g.Suppress = $prevSuppress }
}

function Update-LPUiKbAvailable {
    $g = $script:G
    $f = $g.TxtKbFilter.Text.Trim()
    $g.LstKbAvailable.Items.Clear()
    foreach ($l in $g.Layouts) {
        if ($f -and $l.Name.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and $l.Id.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        [void]$g.LstKbAvailable.Items.Add((New-LPListItem -Type 'ListBoxItem' -Text $l.Display -Tag $l.Id))
    }
}

function Update-LPUiKbSelected {
    param([int]$SelectIndex = -1)
    $g = $script:G
    $g.LstKbSelected.Items.Clear()
    $n = 1
    foreach ($id in $g.Sel.Keyboards) {
        $name = Get-LPLayoutName $id $g.Layouts
        $txt = '{0}. {1}  ({2})' -f $n, $name, $id
        if ($n -eq 1) { $txt += '   - default' }
        [void]$g.LstKbSelected.Items.Add((New-LPListItem -Type 'ListBoxItem' -Text $txt -Tag $id))
        $n++
    }
    if ($SelectIndex -ge 0 -and $SelectIndex -lt $g.LstKbSelected.Items.Count) { $g.LstKbSelected.SelectedIndex = $SelectIndex }
}

function Update-LPUiTargets {
    $g = $script:G
    $prev = @{}
    foreach ($c in $g.PnlTargets.Children) { if ($c -is [System.Windows.Controls.CheckBox]) { $prev[[string]$c.Tag] = [bool]$c.IsChecked } }
    $g.PnlTargets.Children.Clear()
    $defaults = @(Get-LPDefaultTargetIds $g.Snapshot)
    $addBox = {
        param([string]$Tag, [string]$Text, [string]$Tip)
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = New-LPTextBlock -Text $Text -Wrap
        $cb.Tag = $Tag
        $cb.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
        if ($Tip) { $cb.ToolTip = $Tip }
        if ($prev.ContainsKey($Tag)) { $cb.IsChecked = $prev[$Tag] } else { $cb.IsChecked = ($defaults -contains $Tag) }
        $cb.Add_Checked({ Request-LPUiReadiness })
        $cb.Add_Unchecked({ Request-LPUiReadiness })
        [void]$g.PnlTargets.Children.Add($cb)
    }
    $users = @($g.Snapshot.Profiles | Sort-Object @{ Expression = { -not $_.SignedIn } }, Name)
    if ($users.Count -eq 0) { [void]$g.PnlTargets.Children.Add((New-LPTextBlock -Text 'No user profiles found.' -Color '#4A5A6A')) }
    foreach ($p in $users) {
        $state = 'not signed in'
        if ($p.SignedIn) { $state = 'SIGNED IN (session ' + (@($p.SessionIds) -join ', ') + ')' }
        elseif ($p.HiveLoaded) { $state = 'profile loaded, no desktop session' }
        if ($p.IsProcessUser) { $state += ' - this is the elevated account running the tool' }
        if ($p.StateError) { $state += ' - could not be read' }
        & $addBox $p.Id ('{0}   -   {1}' -f $p.Name, $state) ("SID: $($p.Sid)`nProfile: $($p.ProfilePath)")
    }
    $sep = New-Object System.Windows.Controls.Separator
    $sep.Margin = New-Object System.Windows.Thickness(0, 4, 0, 6)
    [void]$g.PnlTargets.Children.Add($sep)
    & $addBox 'lockscreen' 'Lock/welcome screen and system accounts' 'HKU\.DEFAULT (SYSTEM), S-1-5-19, S-1-5-20 and the system preferred UI language'
    & $addBox 'newusers' 'New user accounts (Default profile)' $g.Snapshot.NewUsers.HivePath
}

function Get-LPUiSelection {
    $g = $script:G
    $targets = @(foreach ($c in $g.PnlTargets.Children) { if ($c -is [System.Windows.Controls.CheckBox] -and $c.IsChecked) { [string]$c.Tag } })
    $sysLoc = $g.Sel.SystemLocale
    if (-not $sysLoc) { $sysLoc = $g.Sel.Format }
    return (New-LPSelection -PresetName $g.PresetName -DisplayLanguage $g.Sel.Display -RegionalFormat $g.Sel.Format -GeoId ([int]$g.Sel.GeoId) `
            -Keyboards @($g.Sel.Keyboards) -TargetIds $targets -DisableSync ([bool]$g.ChkSync.IsChecked) -BlockRemoteKeyboard ([bool]$g.ChkRdp.IsChecked) `
            -SetSystemLocale ([bool]$g.ChkSysLocale.IsChecked) -SystemLocale $sysLoc -UninstallOthers ([bool]$g.ChkUninstall.IsChecked) -LanguageSource $g.TxtSource.Text.Trim())
}

function Request-LPUiReadiness {
    $g = $script:G
    if ($g.Suppress) { return }
    $g.ReadyTimer.Stop()
    $g.ReadyTimer.Start()
}

function Set-LPUiModified {
    $g = $script:G
    if ($g.Suppress) { return }
    if ($g.PresetName) { $g.TxtPresetInfo.Text = "$($g.PresetName) (modified) - every field can still be changed." }
}

function Update-LPUiReadiness {
    $g = $script:G
    $g.ReadyTimer.Stop()
    $sel = Get-LPUiSelection
    $g.Selection = $sel
    $ci = Get-LPCultureInfo $sel.SystemLocale
    $g.TxtSysLocaleLabel.Text = 'Set the system locale for non-Unicode programs' + $(if ($ci) { " to $($ci.Name)" } else { '' })
    if (@($sel.Tips).Count -gt 0) {
        $g.TxtKbNote.Text = ('Attached to {0} as {1}. The taskbar shows the display language (e.g. ENG) while typing with these keyboards - expected.' -f $sel.DisplayLanguage, (@($sel.Tips) -join ', '))
    }
    else { $g.TxtKbNote.Text = 'Select at least one keyboard layout.' }
    if (-not $g.Snapshot) {
        $g.TxtReadySummary.Text = 'Scanning this PC...'
        return
    }
    $ready = Test-LPReadiness -Snapshot $g.Snapshot -Selection $sel
    $g.Readiness = $ready
    if ($g.Plan) {
        # The preview no longer matches the selection.
        $g.Plan = $null
        $g.BtnApply.IsEnabled = $false
        $g.BtnApplyReady.Visibility = 'Collapsed'
        Show-LPReportPanel -Panel $g.PnlPreview -Lines @(New-LPLine 'Info' "The selection changed. Click 'Preview changes...' on the Configure tab again.")
    }
    $g.TxtReadySummary.Text = Get-LPReadinessSummary $ready
    if ($ready.HasBlocked) { $g.TxtReadySummary.Foreground = Get-LPBrush '#C62828' } else { $g.TxtReadySummary.Foreground = Get-LPBrush '#2E7D32' }
    Show-LPReportPanel -Panel $g.PnlReadiness -Lines @(Get-LPReadinessLines $ready | Where-Object { $_.Level -ne 'Heading1' })
    $packItem = @($ready.Items | Where-Object { $_.Id -eq 'pack' }) | Select-Object -First 1
    if ($packItem) { $g.TxtDisplayNote.Text = $packItem.Title } else { $g.TxtDisplayNote.Text = '' }
    $g.BtnPreview.IsEnabled = -not $g.Busy
    Show-LPReportPanel -Panel $g.PnlStatus -Lines (Get-LPStatusLines -Snapshot $g.Snapshot -Selection $sel)
}

function Set-LPUiFromPreset {
    param($Preset)
    $g = $script:G
    if (-not $Preset) { return }
    $prevSuppress = $g.Suppress
    $g.Suppress = $true
    try {
        $g.PresetName = $Preset.name
        $c = Get-LPCultureInfo $Preset.displayLanguage
        $g.Sel.Display = $(if ($c) { $c.Name } else { $Preset.displayLanguage })
        $fc = Get-LPCultureInfo $Preset.regionalFormat
        $g.Sel.Format = $(if ($fc) { $fc.Name } else { $Preset.regionalFormat })
        $g.Sel.GeoId = $(if ($Preset.geoId) { [int]$Preset.geoId } else { Get-LPDefaultGeoId $g.Sel.Format })
        $g.Sel.Keyboards = New-Object System.Collections.Generic.List[string]
        foreach ($k in @($Preset.keyboards)) { if ($k -and -not $g.Sel.Keyboards.Contains($k)) { $g.Sel.Keyboards.Add($k) } }
        $g.Sel.SystemLocale = $Preset.systemLocale
        [void](Select-LPItemByTag $g.CmbPreset $Preset.name)
        if (-not (Select-LPItemByTag $g.CmbDisplay $g.Sel.Display)) { Update-LPUiDisplayList }
        $g.TxtFormatFilter.Text = ''
        Update-LPUiFormatList
        Update-LPUiGeoList
        Update-LPUiKbSelected
        $desc = $Preset.description
        if (-not $desc) { $desc = '{0} / {1} / {2}' -f $Preset.displayLanguage, $Preset.regionalFormat, (@($Preset.keyboards) -join ', ') }
        $g.TxtPresetInfo.Text = $desc
    }
    finally { $g.Suppress = $prevSuppress }
    Request-LPUiReadiness
}

function Reset-LPUiDefaults {
    $g = $script:G
    $prevSuppress = $g.Suppress
    $g.Suppress = $true
    try {
        $g.ChkSync.IsChecked = $true
        $g.ChkRdp.IsChecked = $true
        $g.ChkSysLocale.IsChecked = $false
        $g.ChkUninstall.IsChecked = $false
        if ($g.Snapshot) {
            $defaults = @(Get-LPDefaultTargetIds $g.Snapshot)
            foreach ($c in $g.PnlTargets.Children) { if ($c -is [System.Windows.Controls.CheckBox]) { $c.IsChecked = ($defaults -contains [string]$c.Tag) } }
        }
    }
    finally { $g.Suppress = $prevSuppress }
}

function Set-LPUiBusy {
    param([bool]$Busy, [string]$Text)
    $g = $script:G
    $g.Busy = $Busy
    foreach ($n in 'CmbPreset', 'BtnApplyStandard', 'CmbDisplay', 'TxtFormatFilter', 'CmbFormat', 'CmbGeo', 'TxtKbFilter', 'LstKbAvailable', 'LstKbSelected', 'BtnKbAdd', 'BtnKbRemove', 'BtnKbUp', 'BtnKbDown', 'PnlTargets', 'BtnRescan', 'ChkSync', 'ChkRdp', 'ChkSysLocale', 'ChkUninstall', 'TxtSource', 'BtnBrowseSource', 'BtnPreview', 'BtnStatusRefresh', 'BtnRestore', 'BtnRestoreRefresh') {
        $g[$n].IsEnabled = -not $Busy
    }
    if ($Busy) { $g.BtnApply.IsEnabled = $false; $g.BtnApplyReady.IsEnabled = $false }
    else {
        $g.BtnApplyReady.IsEnabled = $true
        $g.BtnRestore.IsEnabled = ($null -ne $g.LstBackups.SelectedItem)
        $g.BtnApplyStandard.IsEnabled = ($null -ne $g.Snapshot)
    }
    if ($Text) { $g.TxtStatusBar.Text = $Text }
}

function Start-LPUiBackground {
    param([string]$Name, [string]$Work, [hashtable]$Arguments, [scriptblock]$OnDone, [string]$LogFile)
    $g = $script:G
    if ($g.Bg) { return $false }
    if (-not $LogFile) { $LogFile = $g.SessionLog }
    $sync = [hashtable]::Synchronized(@{ Log = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'); Cancel = $false; Progress = $null })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($LPBackgroundBootstrap).AddArgument($script:LPEngineText).AddArgument($sync).AddArgument($Work).AddArgument($Arguments).AddArgument($script:LPScriptRoot).AddArgument($LogFile)
    $g.Bg = @{ Name = $Name; PS = $ps; RS = $rs; Sync = $sync; OnDone = $OnDone; Handle = $ps.BeginInvoke() }
    return $true
}

function Invoke-LPUiTick {
    $g = $script:G
    $sb = New-Object System.Text.StringBuilder
    $line = $null
    while ($g.UiLog.TryDequeue([ref]$line)) { [void]$sb.AppendLine($line) }
    $bg = $g.Bg
    if ($bg) { while ($bg.Sync['Log'].TryDequeue([ref]$line)) { [void]$sb.AppendLine($line) } }
    if ($sb.Length -gt 0) { $g.TxtLog.AppendText($sb.ToString()); $g.TxtLog.ScrollToEnd() }
    if (-not $bg) { return }
    $p = $bg.Sync['Progress']
    if ($p -and $p.Text) {
        if ($p.Percent -ge 0) { $g.PrgApply.IsIndeterminate = $false; $g.PrgApply.Value = $p.Percent } else { $g.PrgApply.IsIndeterminate = $true }
        $g.TxtProgress.Text = $p.Text
        $g.BtnCancel.IsEnabled = ([bool]$p.CanCancel -and -not $bg.Sync['Cancel'])
    }
    elseif ($bg.Name -ne 'Scan') {
        $g.PrgApply.IsIndeterminate = $true
        $g.BtnCancel.IsEnabled = $false
    }
    if (-not $bg.Handle.IsCompleted) { return }
    $result = $null; $err = $null
    try {
        $out = $bg.PS.EndInvoke($bg.Handle)
        if ($out -and $out.Count -gt 0) { $result = $out[$out.Count - 1] }
    }
    catch { $err = $_.Exception.Message; if ($_.Exception.InnerException) { $err = $_.Exception.InnerException.Message } }
    $streamErr = @($bg.PS.Streams.Error | ForEach-Object { $_.ToString() })
    if (-not $result -and -not $err -and $streamErr.Count -gt 0) { $err = $streamErr -join "`n" }
    while ($bg.Sync['Log'].TryDequeue([ref]$line)) { [void]$sb.AppendLine($line) }
    if ($sb.Length -gt 0) { $g.TxtLog.AppendText($sb.ToString()); $g.TxtLog.ScrollToEnd() }
    try { $bg.PS.Dispose(); $bg.RS.Dispose() } catch { }
    $g.Bg = $null
    $g.PrgApply.IsIndeterminate = $false
    $g.PrgApply.Value = 0
    $g.TxtProgress.Text = ''
    $g.BtnCancel.IsEnabled = $false
    & $bg.OnDone $result $err
}

function Start-LPUiScan {
    param([switch]$ClearStale)
    $g = $script:G
    Set-LPUiBusy $true 'Scanning this PC (read-only)...'
    $g.TxtReadySummary.Text = 'Scanning this PC...'
    $work = { param($Sync, $A) if ($A.ClearStale) { Clear-LPStaleState }; Get-LPSnapshot }
    $ok = Start-LPUiBackground -Name 'Scan' -Work $work.ToString() -Arguments @{ ClearStale = [bool]$ClearStale } -OnDone {
        param($Result, $Err)
        $g = $script:G
        Set-LPUiBusy $false 'Ready.'
        if ($Err -or -not $Result) {
            [System.Windows.MessageBox]::Show("The scan failed:`n`n$Err", 'Language Profile', 'OK', 'Error') | Out-Null
            $g.TxtStatusBar.Text = 'Scan failed - see log.'
            return
        }
        $g.Snapshot = $Result
        $os = ''
        if ($Result.Os) { $os = $Result.Os.Name }
        $signed = @($Result.Profiles | Where-Object { $_.SignedIn } | ForEach-Object { $_.Name })
        $g.TxtContext.Text = ('{0}   |   Running as {1} (elevated)   |   Signed in: {2}' -f $os, $Result.Process.UserName, $(if ($signed.Count) { $signed -join ', ' } else { 'nobody' }))
        Update-LPUiDisplayList
        Update-LPUiTargets
        Update-LPUiReadiness
        $g.TxtStatusBar.Text = ('Scan finished {0:HH:mm:ss}. Log: {1}' -f $Result.ScanTime, $g.SessionLog)
    }
    if (-not $ok) { Set-LPUiBusy $false }
}

function Show-LPUiPreview {
    $g = $script:G
    if (-not $g.Snapshot) { return }
    Update-LPUiReadiness
    $plan = New-LPPlan -Snapshot $g.Snapshot -Selection $g.Selection -Readiness $g.Readiness
    $g.Plan = $plan
    $lines = @()
    $lines += Get-LPReadinessLines $g.Readiness
    $lines += New-LPLine 'Heading1' 'Preview'
    $lines += $plan.Lines
    Show-LPReportPanel -Panel $g.PnlPreview -Lines $lines
    $g.BtnApply.IsEnabled = ($g.Readiness.CanApply -and $plan.Executable -and -not $g.Busy)
    if ($g.Readiness.CanApplyReadyParts) { $g.BtnApplyReady.Visibility = 'Visible' } else { $g.BtnApplyReady.Visibility = 'Collapsed' }
    $g.Tabs.SelectedItem = $g.TabApply
}

function Start-LPUiApply {
    param([switch]$ReadyPartsOnly, $Plan)
    $g = $script:G
    if ($g.Bg) { return }
    if (-not $Plan) {
        Update-LPUiReadiness
        $Plan = New-LPPlan -Snapshot $g.Snapshot -Selection $g.Selection -Readiness $g.Readiness -ReadyPartsOnly:$ReadyPartsOnly
    }
    if (-not $Plan.Executable) {
        [System.Windows.MessageBox]::Show('Nothing can be applied. See the readiness list.', 'Language Profile', 'OK', 'Information') | Out-Null
        return
    }
    $text = Get-LPPlanSummaryText -Plan $Plan -Snapshot $g.Snapshot
    $icon = 'Question'
    $title = 'Apply language profile?'
    if ($ReadyPartsOnly) {
        $icon = 'Warning'
        $title = 'PARTIAL apply - only the parts that are ready'
        $text = "Some prerequisites are BLOCKED. Only the parts that are ready will be applied; the blocked parts stay unchanged and the PC will NOT be fully standardized.`n`n" + $text
    }
    $answer = [System.Windows.MessageBox]::Show($text + "`n`nContinue?", $title, 'YesNo', $icon)
    if ([string]$answer -ne 'Yes') { return }
    $g.Plan = $null
    $g.Tabs.SelectedItem = $g.TabApply
    Show-LPReportPanel -Panel $g.PnlPreview -Lines $Plan.Lines
    $applyLog = New-LPLogFile -Name 'Apply'
    $g.CurrentLog = $applyLog
    $g.TxtLog.AppendText("`r`n---- Apply started. Log file: $applyLog`r`n")
    Set-LPUiBusy $true 'Applying... do not close the window.'
    $work = { param($Sync, $A) Invoke-LPPlan -Plan $A.Plan -Snapshot $A.Snapshot -Sync $Sync -TaskTimeoutMinutes $A.Timeout }
    $ok = Start-LPUiBackground -Name 'Apply' -Work $work.ToString() -Arguments @{ Plan = $Plan; Snapshot = $g.Snapshot; Timeout = $g.TaskTimeout } -LogFile $applyLog -OnDone {
        param($Result, $Err)
        $g = $script:G
        Set-LPUiBusy $false 'Apply finished.'
        if ($Err -or -not $Result) {
            [System.Windows.MessageBox]::Show("Apply stopped with an error:`n`n$Err`n`nSee the log. A backup of everything changed so far is on the Restore tab.", 'Language Profile', 'OK', 'Error') | Out-Null
        }
        else {
            Show-LPReportPanel -Panel $g.PnlPreview -Lines $Result.Lines
            $msg = (Format-LPReportText $Result.Lines).Trim()
            $icon = 'Information'
            if ($Result.Outcome -eq 'Error' -or $Result.Outcome -eq 'Blocked') { $icon = 'Error' } elseif ($Result.Outcome -eq 'Partial' -or $Result.Outcome -eq 'Cancelled') { $icon = 'Warning' }
            if ($Result.RestartNeeded) {
                $a = [System.Windows.MessageBox]::Show($msg + "`n`nRestart the PC now?", 'Language Profile', 'YesNo', $icon)
                if ([string]$a -eq 'Yes') { Restart-Computer -Force; return }
            }
            else { [System.Windows.MessageBox]::Show($msg, 'Language Profile', 'OK', $icon) | Out-Null }
        }
        Update-LPUiBackups
        Start-LPUiScan
    }
    if (-not $ok) { Set-LPUiBusy $false }
}

function Invoke-LPUiApplyStandard {
    $g = $script:G
    if (-not $g.Snapshot -or $g.Bg) { return }
    $std = Find-LPPreset $g.Presets 'Standard'
    Set-LPUiFromPreset $std
    Reset-LPUiDefaults
    Update-LPUiReadiness
    $plan = New-LPPlan -Snapshot $g.Snapshot -Selection $g.Selection -Readiness $g.Readiness
    if (-not $g.Readiness.CanApply) {
        Show-LPUiPreview
        $blockedTitles = @($g.Readiness.Items | Where-Object { $_.State -eq 'Blocked' } | ForEach-Object { '- ' + $_.Title })
        $msg = "The standard setup cannot be applied completely yet. Nothing was changed.`n`n" + ($blockedTitles -join "`n") + "`n`nThe readiness list shows what to do. After fixing it, click 'Apply standard setup' again."
        if ($g.Readiness.CanApplyReadyParts) { $msg += "`n`nAlternatively you can explicitly apply only the parts that are ready (button on this tab)." }
        [System.Windows.MessageBox]::Show($msg, 'Language Profile', 'OK', 'Warning') | Out-Null
        return
    }
    Start-LPUiApply -Plan $plan
}

function Update-LPUiBackups {
    $g = $script:G
    $g.LstBackups.Items.Clear()
    foreach ($b in @(Get-LPBackups)) { [void]$g.LstBackups.Items.Add((New-LPListItem -Type 'ListBoxItem' -Text $b.Display -Tag $b.Path)) }
    $g.TxtBackupRoot.Text = 'Backups: ' + (Join-Path (Get-LPDataRoot) 'Backups')
    $g.BtnRestore.IsEnabled = $false
}

function Start-LPUiRestore {
    $g = $script:G
    $item = $g.LstBackups.SelectedItem
    if (-not $item -or $g.Bg) { return }
    $a = [System.Windows.MessageBox]::Show("Restore this backup?`n`n$($item.Content)`n`nThe registry keys are written back as they were before that run. Installed or removed language packs are NOT rolled back. A new backup of the current state is made first.", 'Language Profile', 'YesNo', 'Question')
    if ([string]$a -ne 'Yes') { return }
    $log = New-LPLogFile -Name 'Restore'
    $g.CurrentLog = $log
    $g.Tabs.SelectedItem = $g.TabApply
    $g.TxtLog.AppendText("`r`n---- Restore started. Log file: $log`r`n")
    Set-LPUiBusy $true 'Restoring...'
    $work = { param($Sync, $A) Clear-LPStaleState; Restore-LPBackup -Path $A.Path }
    $ok = Start-LPUiBackground -Name 'Restore' -Work $work.ToString() -Arguments @{ Path = [string]$item.Tag } -LogFile $log -OnDone {
        param($Result, $Err)
        $g = $script:G
        Set-LPUiBusy $false 'Restore finished.'
        if ($Err -or -not $Result) { [System.Windows.MessageBox]::Show("Restore failed:`n`n$Err", 'Language Profile', 'OK', 'Error') | Out-Null }
        else {
            Show-LPReportPanel -Panel $g.PnlPreview -Lines $Result.Lines
            [System.Windows.MessageBox]::Show((Format-LPReportText $Result.Lines).Trim(), 'Language Profile', 'OK', 'Information') | Out-Null
        }
        Update-LPUiBackups
        Start-LPUiScan
    }
    if (-not $ok) { Set-LPUiBusy $false }
}

function Hide-LPConsole {
    try {
        if (-not ('LanguageProfileNative.Win32' -as [type])) {
            Add-Type -Namespace LanguageProfileNative -Name Win32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
        }
        $h = [LanguageProfileNative.Win32]::GetConsoleWindow()
        if ($h -ne [IntPtr]::Zero) { [void][LanguageProfileNative.Win32]::ShowWindow($h, 0) }
    }
    catch { }
}

function Start-LPGui {
    param([string]$InitialPreset, [int]$TaskTimeoutMinutes = 10)
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
    Hide-LPConsole

    $uiLog = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $sessionLog = Initialize-LPEngine -ScriptRoot $script:LPScriptRoot -LogQueue $uiLog -LogName 'Session'

    [xml]$xml = $LPXaml
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xml))
    $script:G = @{
        Window      = $window
        UiLog       = $uiLog
        SessionLog  = $sessionLog
        CurrentLog  = $sessionLog
        Suppress    = $false
        Busy        = $false
        Bg          = $null
        Snapshot    = $null
        Selection   = $null
        Readiness   = $null
        Plan        = $null
        PresetName  = $null
        TaskTimeout = $TaskTimeoutMinutes
        Sel         = @{ Display = $null; Format = $null; GeoId = 0; Keyboards = (New-Object System.Collections.Generic.List[string]); SystemLocale = $null }
    }
    $g = $script:G
    foreach ($m in [regex]::Matches($LPXaml, 'x:Name="(\w+)"')) { $n = $m.Groups[1].Value; $g[$n] = $window.FindName($n) }

    # Static lists
    $presetInfo = Get-LPPresets
    $g.Presets = $presetInfo.Presets
    foreach ($p in $g.Presets) { [void]$g.CmbPreset.Items.Add((New-LPListItem -Text $p.name -Tag $p.name)) }
    if (@($presetInfo.Warnings).Count -gt 0) { $g.TxtStatusBar.Text = (@($presetInfo.Warnings) -join ' ') }
    $g.Formats = @(Get-LPFormatCatalog)
    $g.Geos = @(Get-LPGeoCatalog)
    $g.Layouts = @(Get-LPKeyboardLayouts)
    Update-LPUiDisplayList
    Update-LPUiKbAvailable

    $g.ReadyTimer = New-Object System.Windows.Threading.DispatcherTimer
    $g.ReadyTimer.Interval = [TimeSpan]::FromMilliseconds(350)
    $g.ReadyTimer.Add_Tick({ Update-LPUiReadiness })
    $g.Ticker = New-Object System.Windows.Threading.DispatcherTimer
    $g.Ticker.Interval = [TimeSpan]::FromMilliseconds(250)
    $g.Ticker.Add_Tick({ try { Invoke-LPUiTick } catch { $script:G.TxtStatusBar.Text = 'UI error: ' + $_.Exception.Message } })

    # Events
    $g.CmbPreset.Add_SelectionChanged({
            $g = $script:G
            if ($g.Suppress -or -not $g.CmbPreset.SelectedItem) { return }
            Set-LPUiFromPreset (Find-LPPreset $g.Presets ([string]$g.CmbPreset.SelectedItem.Tag))
        })
    $g.CmbDisplay.Add_SelectionChanged({
            $g = $script:G
            if ($g.Suppress -or -not $g.CmbDisplay.SelectedItem) { return }
            $g.Sel.Display = [string]$g.CmbDisplay.SelectedItem.Tag
            Set-LPUiModified; Request-LPUiReadiness
        })
    $g.TxtFormatFilter.Add_TextChanged({ Update-LPUiFormatList })
    $g.CmbFormat.Add_SelectionChanged({
            $g = $script:G
            if ($g.Suppress -or -not $g.CmbFormat.SelectedItem -or -not [string]$g.CmbFormat.SelectedItem.Tag) { return }
            $g.Sel.Format = [string]$g.CmbFormat.SelectedItem.Tag
            $geo = Get-LPDefaultGeoId $g.Sel.Format
            if ($geo -gt 0) { $g.Sel.GeoId = $geo; Update-LPUiGeoList }
            $ci = Get-LPCultureInfo $g.Sel.Format
            if ($ci) { $g.TxtFormatSelected.Text = 'Selected: {0} ({1})  -  e.g. {2}' -f $ci.EnglishName, $ci.Name, ((Get-Date).ToString('d', $ci) + ' ' + (1234567.89).ToString('N2', $ci)) }
            Set-LPUiModified; Request-LPUiReadiness
        })
    $g.CmbGeo.Add_SelectionChanged({
            $g = $script:G
            if ($g.Suppress -or -not $g.CmbGeo.SelectedItem) { return }
            $g.Sel.GeoId = [int]$g.CmbGeo.SelectedItem.Tag
            Set-LPUiModified; Request-LPUiReadiness
        })
    $g.TxtKbFilter.Add_TextChanged({ Update-LPUiKbAvailable })
    $addKb = {
        $g = $script:G
        foreach ($i in @($g.LstKbAvailable.SelectedItems)) { $id = [string]$i.Tag; if (-not $g.Sel.Keyboards.Contains($id)) { $g.Sel.Keyboards.Add($id) } }
        Update-LPUiKbSelected; Set-LPUiModified; Request-LPUiReadiness
    }
    $g.BtnKbAdd.Add_Click($addKb)
    $g.LstKbAvailable.Add_MouseDoubleClick($addKb)
    $g.BtnKbRemove.Add_Click({
            $g = $script:G
            $i = $g.LstKbSelected.SelectedItem
            if (-not $i) { return }
            [void]$g.Sel.Keyboards.Remove([string]$i.Tag)
            Update-LPUiKbSelected; Set-LPUiModified; Request-LPUiReadiness
        })
    $g.BtnKbUp.Add_Click({
            $g = $script:G
            $ix = $g.LstKbSelected.SelectedIndex
            if ($ix -le 0) { return }
            $id = $g.Sel.Keyboards[$ix]; $g.Sel.Keyboards.RemoveAt($ix); $g.Sel.Keyboards.Insert($ix - 1, $id)
            Update-LPUiKbSelected -SelectIndex ($ix - 1); Set-LPUiModified; Request-LPUiReadiness
        })
    $g.BtnKbDown.Add_Click({
            $g = $script:G
            $ix = $g.LstKbSelected.SelectedIndex
            if ($ix -lt 0 -or $ix -ge $g.Sel.Keyboards.Count - 1) { return }
            $id = $g.Sel.Keyboards[$ix]; $g.Sel.Keyboards.RemoveAt($ix); $g.Sel.Keyboards.Insert($ix + 1, $id)
            Update-LPUiKbSelected -SelectIndex ($ix + 1); Set-LPUiModified; Request-LPUiReadiness
        })
    foreach ($n in 'ChkSync', 'ChkRdp', 'ChkSysLocale', 'ChkUninstall') {
        $g[$n].Add_Checked({ Request-LPUiReadiness })
        $g[$n].Add_Unchecked({ Request-LPUiReadiness })
    }
    $g.TxtSource.Add_TextChanged({ Request-LPUiReadiness })
    $g.BtnBrowseSource.Add_Click({
            $d = New-Object System.Windows.Forms.FolderBrowserDialog
            $d.Description = 'Folder with the language pack CAB (Microsoft-Windows-Client-Language-Pack_x64_xx-xx.cab)'
            if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $script:G.TxtSource.Text = $d.SelectedPath }
        })
    $g.BtnRescan.Add_Click({ Start-LPUiScan })
    $g.BtnStatusRefresh.Add_Click({ Start-LPUiScan })
    $g.BtnPreview.Add_Click({ Show-LPUiPreview })
    $g.BtnApply.Add_Click({ Start-LPUiApply })
    $g.BtnApplyReady.Add_Click({ Start-LPUiApply -ReadyPartsOnly })
    $g.BtnCancel.Add_Click({
            $g = $script:G
            if ($g.Bg) { $g.Bg.Sync['Cancel'] = $true; $g.BtnCancel.IsEnabled = $false; $g.TxtProgress.Text = 'Cancelling...' }
        })
    $g.BtnOpenLog.Add_Click({ Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\notepad.exe') -ArgumentList ('"{0}"' -f $script:G.CurrentLog) })
    $g.BtnApplyStandard.Add_Click({ Invoke-LPUiApplyStandard })
    $g.LstBackups.Add_SelectionChanged({ $script:G.BtnRestore.IsEnabled = ($null -ne $script:G.LstBackups.SelectedItem -and -not $script:G.Busy) })
    $g.BtnRestore.Add_Click({ Start-LPUiRestore })
    $g.BtnRestoreRefresh.Add_Click({ Update-LPUiBackups })
    $window.Add_Closing({
            param($s, $e)
            $bg = $script:G.Bg
            if ($bg) {
                # Never exit while a profile hive may be loaded: a hive left loaded gives that user a temporary profile.
                $m = 'Please wait until the current run has finished.'
                if ($bg.Name -eq 'Scan') { $m = 'The scan is still reading user profiles. Please wait a moment.' }
                [System.Windows.MessageBox]::Show($m, 'Language Profile', 'OK', 'Warning') | Out-Null
                $e.Cancel = $true
            }
        })

    # Initial state: Standard (or the requested preset) preselected
    $start = $null
    if ($InitialPreset) { $start = Find-LPPreset $g.Presets $InitialPreset }
    if (-not $start) { $start = Find-LPPreset $g.Presets 'Standard' }
    Set-LPUiFromPreset $start
    Update-LPUiBackups
    $g.TxtContext.Text = 'Running as ' + [Security.Principal.WindowsIdentity]::GetCurrent().Name + ' (elevated). Scanning this PC...'
    $g.Ticker.Start()
    $window.Add_ContentRendered({ Start-LPUiScan -ClearStale })
    [void]$window.ShowDialog()
    $g.Ticker.Stop()
}

# ================================================================================================
# 3. CLI (unattended: Intune/SCCM, also as SYSTEM)
# ================================================================================================
function Invoke-LPCli {
    param([Parameter(Mandatory)][hashtable]$P)
    $codes = Get-LPExitCodes
    $logName = 'Apply'
    if ($P.Restore) { $logName = 'Restore' } elseif ($P.Status) { $logName = 'Status' } elseif ($P.Verify) { $logName = 'Verify' } elseif ($P.Preview) { $logName = 'Preview' }
    $log = Initialize-LPEngine -ScriptRoot $script:LPScriptRoot -Console:(-not $P.Json) -LogName $logName
    Write-LPLog "Language Profile $(Get-LPVersion) - $logName - log: $log" -Level Step
    try {
        if ($P.Restore) {
            Clear-LPStaleState
            $r = Restore-LPBackup -Path $P.Restore
            if ($P.Json) { [Console]::Out.WriteLine(($r | ConvertTo-Json -Depth 8)) } else { Write-LPReport $r.Lines }
            return $r.ExitCode
        }

        $presetInfo = Get-LPPresets
        $preset = $null
        if ($P.Preset) {
            $preset = Find-LPPreset $presetInfo.Presets $P.Preset
            if (-not $preset) {
                Write-LPLog ("Unknown preset '{0}'. Available: {1}" -f $P.Preset, (@($presetInfo.Presets | ForEach-Object { $_.name }) -join ', ')) -Level Error
                return $codes.Error
            }
        }
        elseif (-not $P.DisplayLanguage) {
            if ($P.Verify -or $P.Preview -or $P.Status) { $preset = Find-LPPreset $presetInfo.Presets 'Standard' }
            else {
                Write-LPLog 'Specify -Preset <name> (e.g. -Preset Standard) or -DisplayLanguage, -RegionalFormat and -Keyboard.' -Level Error
                return $codes.Error
            }
        }
        $disp = $P.DisplayLanguage; $fmt = $P.RegionalFormat; $geo = [int]$P.GeoId; $kbs = @($P.Keyboard); $sysLoc = $P.SystemLocale
        if ($preset) {
            if (-not $disp) { $disp = $preset.displayLanguage }
            if (-not $fmt) { $fmt = $preset.regionalFormat }
            if ($geo -le 0 -and -not $P.RegionalFormat) { $geo = [int]$preset.geoId }
            if ($kbs.Count -eq 0) { $kbs = @($preset.keyboards) }
            if (-not $sysLoc) { $sysLoc = $preset.systemLocale }
        }
        $kbs = @($kbs | ForEach-Object { ([string]$_).Split(',; '.ToCharArray()) } | Where-Object { $_ })
        if (-not $disp -or -not $fmt -or $kbs.Count -eq 0) {
            if (-not $P.Status) {
                Write-LPLog 'A display language, a regional format and at least one keyboard are required.' -Level Error
                return $codes.Error
            }
        }

        $applying = -not ($P.Status -or $P.Verify -or $P.Preview)
        if ($applying) { Clear-LPStaleState }
        $snap = Get-LPSnapshot

        $sel = $null
        if ($disp) {
            $targetIds = @(Resolve-LPTargetIds -Snapshot $snap -Target @($P.Target))
            $sel = New-LPSelection -PresetName $(if ($preset) { $preset.name } else { $null }) -DisplayLanguage $disp -RegionalFormat $fmt -GeoId $geo -Keyboards $kbs -TargetIds $targetIds `
                -DisableSync (-not $P.KeepLanguageSync) -BlockRemoteKeyboard (-not $P.AllowRemoteKeyboardLayout) -SetSystemLocale ([bool]$P.SetSystemLocale) -SystemLocale $sysLoc `
                -UninstallOthers ([bool]$P.UninstallOtherLanguages) -LanguageSource $P.LanguageSource
        }

        if ($P.Status) {
            if ($P.Json) { [Console]::Out.WriteLine(($snap | ConvertTo-Json -Depth 10)) }
            else { Write-LPReport (Get-LPStatusLines -Snapshot $snap -Selection $sel) }
            return $codes.Done
        }
        if ($P.Verify) {
            $c = @(Test-LPCompliance -Snapshot $snap -Selection $sel)
            if ($P.Json) { [Console]::Out.WriteLine((ConvertTo-Json -InputObject $c -Depth 6)) }
            else {
                foreach ($x in $c) {
                    if ($x.Compliant) { Write-LPReport @(New-LPLine 'OK' "$($x.Name): matches") }
                    else { Write-LPReport @(New-LPLine 'Warn' "$($x.Name): does not match" $x.Issues) }
                }
            }
            if (@($c | Where-Object { -not $_.Compliant }).Count -gt 0) { return $codes.NotCompliant }
            return $codes.Done
        }

        $ready = Test-LPReadiness -Snapshot $snap -Selection $sel
        $plan = New-LPPlan -Snapshot $snap -Selection $sel -Readiness $ready -ReadyPartsOnly:([bool]$P.ApplyReadyParts)
        if ($P.Json -and $P.Preview) {
            [Console]::Out.WriteLine(([pscustomobject]@{ Readiness = $ready; Plan = ($plan | Select-Object Parts, SkippedParts, ReadyPartsOnly, Executable, PredictRestart, PredictSignOut, Lines) } | ConvertTo-Json -Depth 8))
        }
        else {
            Write-LPReport (Get-LPReadinessLines $ready)
            Write-Host ''
            Write-Host (Get-LPReadinessSummary $ready) -ForegroundColor $(if ($ready.HasBlocked) { 'Red' } else { 'Green' })
            Write-LPReport (@(New-LPLine 'Heading1' 'Preview') + @($plan.Lines))
        }
        Write-LPLog ('Readiness: ' + (Get-LPReadinessSummary $ready)) -Level Info
        if ($P.Preview) {
            if ($ready.HasBlocked) { return $codes.Blocked }
            return $codes.Done
        }
        if ($ready.HasBlocked -and -not $P.ApplyReadyParts) {
            Write-LPLog 'Blocked by a missing prerequisite. Nothing was changed. (Use -ApplyReadyParts to apply only the parts that are ready.)' -Level Error
            return $codes.Blocked
        }
        if (-not $plan.Executable) {
            Write-LPLog 'Nothing can be applied. Nothing was changed.' -Level Error
            return $codes.Blocked
        }
        $res = Invoke-LPPlan -Plan $plan -Snapshot $snap -TaskTimeoutMinutes $P.TaskTimeoutMinutes
        Write-LPReport $res.Lines
        return $res.ExitCode
    }
    catch {
        Write-LPLog ("ERROR: " + $_.Exception.Message) -Level Error
        Write-LPLog ($_.ScriptStackTrace) -Level Detail
        return $codes.Error
    }
}

# ================================================================================================
# 4. ENTRY POINT
# ================================================================================================
$script:LPScriptRoot = $PSScriptRoot
$script:LPEngineText = $LPEngineScript.ToString()

function ConvertTo-LPQuotedArg {
    param([string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $v = $Value -replace '(\\*)"', '$1$1\"'
    $v = $v -replace '(\\+)$', '$1$1'
    return '"' + $v + '"'
}

function Get-LPForwardArgs {
    param([hashtable]$Bound)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($k in $Bound.Keys) {
        $v = $Bound[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $list.Add("-$k") } }
        elseif ($v -is [array]) { $list.Add("-$k"); $list.Add((@($v) -join ',')) }
        else { $list.Add("-$k"); $list.Add([string]$v) }
    }
    return $list.ToArray()
}

$bound = @{}
foreach ($k in $PSBoundParameters.Keys) { $bound[$k] = $PSBoundParameters[$k] }
$cliKeys = 'Preset', 'DisplayLanguage', 'RegionalFormat', 'GeoId', 'Keyboard', 'Target', 'KeepLanguageSync', 'AllowRemoteKeyboardLayout', 'SetSystemLocale', 'SystemLocale',
'UninstallOtherLanguages', 'LanguageSource', 'ApplyReadyParts', 'Preview', 'Status', 'Verify', 'Json', 'Restore', 'NoUI'
$isCli = (-not $Gui) -and (@($bound.Keys | Where-Object { $cliKeys -contains $_ }).Count -gt 0)
$psExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

# 64-bit PowerShell is required (registry/file redirection, LanguagePackManagement). Intune and SCCM
# may start a 32-bit host.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $ps64 = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    $fwd = Get-LPForwardArgs $bound
    & $ps64 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @fwd
    exit $LASTEXITCODE
}

# Elevation. Works with a different admin account (over-the-shoulder): targets are always handled by
# SID, never through HKCU of the elevated account.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ($Elevated) {
        [Console]::Error.WriteLine('Language Profile: elevation did not result in administrator rights.')
        exit 1
    }
    $fwd = @(Get-LPForwardArgs $bound) + '-Elevated'
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-LPQuotedArg $PSCommandPath) + ' ' + ((@($fwd) | ForEach-Object { ConvertTo-LPQuotedArg $_ }) -join ' ')
    try {
        if ($isCli) {
            Write-Host 'Language Profile needs administrator rights - confirm the UAC prompt. Output goes to the elevated window and to the log under %ProgramData%\LanguageProfile\Logs.'
            $proc = Start-Process -FilePath $psExe -ArgumentList $argLine -Verb RunAs -PassThru -Wait
            exit $proc.ExitCode
        }
        Start-Process -FilePath $psExe -ArgumentList $argLine -Verb RunAs -WindowStyle Hidden | Out-Null
        exit 0
    }
    catch {
        [Console]::Error.WriteLine('Language Profile needs administrator rights (any administrator account). The UAC prompt was cancelled or failed: ' + $_.Exception.Message)
        exit 1
    }
}

# WPF needs an STA thread (powershell.exe -File is STA by default; this is a safety net).
if (-not $isCli -and [Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    $fwd = Get-LPForwardArgs $bound
    & $psExe -STA -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @fwd
    exit $LASTEXITCODE
}

New-Module -Name LanguageProfileEngine -ScriptBlock $LPEngineScript | Import-Module -Force -DisableNameChecking

# One instance at a time for anything that may change the PC.
$readOnly = $isCli -and ($Status -or $Verify -or $Preview)
$mutex = $null
if (-not $readOnly) {
    $mutex = New-Object System.Threading.Mutex($false, 'Global\LanguageProfileTool')
    $owned = $false
    try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) {
        $msg = 'Language Profile is already running on this PC (another window or an Intune/SCCM run). Try again when it has finished.'
        if ($isCli) { [Console]::Error.WriteLine($msg) }
        else { Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show($msg, 'Language Profile', 'OK', 'Warning') | Out-Null }
        exit 1
    }
}

$exitCode = 0
try {
    if ($isCli) {
        $cliParams = @{
            Preset = $Preset; DisplayLanguage = $DisplayLanguage; RegionalFormat = $RegionalFormat; GeoId = $GeoId
            Keyboard = @($Keyboard | Where-Object { $_ }); Target = @($Target | Where-Object { $_ })
            KeepLanguageSync = [bool]$KeepLanguageSync; AllowRemoteKeyboardLayout = [bool]$AllowRemoteKeyboardLayout
            SetSystemLocale = [bool]$SetSystemLocale; SystemLocale = $SystemLocale; UninstallOtherLanguages = [bool]$UninstallOtherLanguages
            LanguageSource = $LanguageSource; ApplyReadyParts = [bool]$ApplyReadyParts; Preview = [bool]$Preview; Status = [bool]$Status
            Verify = [bool]$Verify; Json = [bool]$Json; Restore = $Restore; TaskTimeoutMinutes = $TaskTimeoutMinutes
        }
        $exitCode = [int](Invoke-LPCli -P $cliParams | Select-Object -Last 1)
    }
    else {
        try { Start-LPGui -InitialPreset $Preset -TaskTimeoutMinutes $TaskTimeoutMinutes }
        catch {
            try { Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show("Language Profile could not start:`n`n$($_.Exception.Message)`n`n$($_.ScriptStackTrace)", 'Language Profile', 'OK', 'Error') | Out-Null } catch { }
            $exitCode = 1
        }
    }
}
finally {
    if ($mutex) { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose() }
}
exit $exitCode
