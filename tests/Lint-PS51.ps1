<#
.SYNOPSIS
    Static checks for LanguageProfile.ps1 that can run anywhere PowerShell 7 runs (also Linux/CI):
    parse errors, PowerShell 7-only syntax/parameters that break Windows PowerShell 5.1, non-ASCII
    characters (5.1 reads BOM-less scripts as ANSI), XAML well-formedness and x:Name references.
#>
param([string]$Path = (Join-Path $PSScriptRoot '..\LanguageProfile.ps1'))
$ErrorActionPreference = 'Stop'
$fail = 0
function Report([string]$msg) { Write-Host "FAIL: $msg" -ForegroundColor Red; $script:fail++ }

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Path), [ref]$tokens, [ref]$errors)
foreach ($e in $errors) { Report ("parse error line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) }

# Engine and worker script blocks parse too (worker is a here-string).
$text = [IO.File]::ReadAllText((Resolve-Path $Path))
$m = [regex]::Match($text, "(?s)\`$script:WorkerText = @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { Report 'worker here-string not found' }
else {
    $wt = $m.Groups[1].Value.Replace('#__LP_HELPERS__', '')
    $we = $null; $wtok = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($wt, [ref]$wtok, [ref]$we)
    foreach ($e in $we) { Report ("worker parse error line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) }
}
foreach ($name in 'LPBackgroundBootstrap') {
    $m2 = [regex]::Match($text, "(?s)\`$$name = @'\r?\n(.*?)\r?\n'@")
    if (-not $m2.Success) { Report "$name not found" } else {
        $be = $null; $bt = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($m2.Groups[1].Value, [ref]$bt, [ref]$be)
        foreach ($e in $be) { Report ("$name parse error: {0}" -f $e.Message) }
    }
}

# PowerShell 7-only syntax
$ps7 = $ast.FindAll({ param($n)
        $n.GetType().Name -in 'TernaryExpressionAst', 'PipelineChainAst' -or
        ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -and $n.Operator -eq 'QuestionQuestion') -or
        ($n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Operator -eq 'QuestionQuestionEquals') -or
        ($n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.NullConditional)
    }, $true)
foreach ($n in $ps7) { Report ("PowerShell 7-only syntax at line {0}: {1}" -f $n.Extent.StartLineNumber, $n.Extent.Text) }

# Parameters that do not exist in 5.1
$bad = @{
    'ConvertFrom-Json' = @('AsHashtable', 'Depth', 'NoEnumerate')
    'Join-Path'        = @('AdditionalChildPath')
    'Get-Content'      = @('AsByteStream')
    'ForEach-Object'   = @('Parallel', 'ThrottleLimit')
    'Out-File'         = @()
    'Select-Object'    = @('SkipLast')
    'Test-Path'        = @()
}
$cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
foreach ($c in $cmds) {
    $name = $c.GetCommandName()
    if ($name -and $bad.ContainsKey($name)) {
        foreach ($p in $c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] }) {
            if ($bad[$name] -contains $p.ParameterName) { Report ("{0} -{1} is not available in 5.1 (line {2})" -f $name, $p.ParameterName, $c.Extent.StartLineNumber) }
        }
    }
    if ($name -in 'Test-Json', 'Get-Error', 'Join-String', 'ConvertTo-CliXml') { Report "$name does not exist in 5.1 (line $($c.Extent.StartLineNumber))" }
    foreach ($p in $c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] }) {
        if ($p.Value -in 'utf8NoBOM', 'utf8BOM') { Report "Encoding $($p.Value) is not available in 5.1 (line $($c.Extent.StartLineNumber))" }
    }
}
$vars = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -in 'PSStyle', 'IsWindows', 'IsLinux', 'IsMacOS', 'IsCoreCLR' }, $true)
foreach ($v in $vars) { Report ("variable `${0} does not exist in 5.1 (line {1})" -f $v.VariablePath.UserPath, $v.Extent.StartLineNumber) }

# Non-ASCII characters
$lineNo = 0
foreach ($line in [IO.File]::ReadAllLines((Resolve-Path $Path))) {
    $lineNo++
    if ($line -match '[^\x00-\x7F]') { Report "non-ASCII character on line $lineNo" }
}

# XAML
$xm = [regex]::Match($text, "(?s)\`$LPXaml = @'\r?\n(.*?)\r?\n'@")
if (-not $xm.Success) { Report 'XAML not found' }
else {
    try { [xml]$x = $xm.Groups[1].Value } catch { Report "XAML is not well-formed: $($_.Exception.Message)" }
    $names = @([regex]::Matches($xm.Groups[1].Value, 'x:Name="(\w+)"') | ForEach-Object { $_.Groups[1].Value })
    $dups = @($names | Group-Object | Where-Object { $_.Count -gt 1 })
    foreach ($d in $dups) { Report "duplicate x:Name $($d.Name)" }
    if ($xm.Groups[1].Value -match '\s(Click|Checked|SelectionChanged|x:Class)=') { Report 'XAML contains event handlers or x:Class (not supported by XamlReader)' }
    # every $g.<Name> that looks like a control must exist
    $refs = @([regex]::Matches($text, '\$g\.((?:Btn|Txt|Cmb|Lst|Chk|Pnl|Prg|Tab)\w+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $refs += @([regex]::Matches($text, "'((?:Btn|Txt|Cmb|Lst|Chk|Pnl|Prg|Tab)\w+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    foreach ($r in ($refs | Select-Object -Unique)) { if ($names -notcontains $r) { Report "control $r is used but not defined in the XAML" } }
}

if ($fail -eq 0) { Write-Host 'Lint OK' -ForegroundColor Green; exit 0 }
Write-Host "$fail problem(s)" -ForegroundColor Red
exit 1
