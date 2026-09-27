<#
.SYNOPSIS
    Generate sing-box rule-set source files (.json) from the Surge .list rules
    shipped in this repository (blackmatrix7/ios_rule_script).

.DESCRIPTION
    sing-box (https://sing-box.sagernet.org) uses "rule-set" files for routing.
    This script converts the existing Surge `.list` rules into the sing-box
    rule-set *source* format (JSON), which can be used directly with
    `"format": "source"` or compiled to a binary `.srs` with
    `sing-box rule-set compile`.

    Field mapping (Surge -> sing-box headless rule):
        DOMAIN          -> domain
        DOMAIN-SUFFIX   -> domain_suffix
        DOMAIN-KEYWORD  -> domain_keyword
        IP-CIDR         -> ip_cidr
        IP-CIDR6        -> ip_cidr
        PROCESS-NAME    -> process_name   (emitted as a separate rule object,
                                           see note below)
        IP-ASN          -> skipped (no rule-set equivalent)
        USER-AGENT      -> skipped (no rule-set equivalent)
        URL-REGEX       -> skipped (HTTP layer only, no rule-set equivalent)
        AND / OR / NOT  -> skipped (logical rules are not translated)

    Domain-set style lines (no type prefix, used by the AdGuard*_Domain lists):
        ".example.com"  -> domain_suffix "example.com"   (leading dot stripped)
        "example.com"   -> domain

    Matching note:
        A sing-box default rule ANDs its "other fields" with the domain/ip group:
            (domain || domain_suffix || domain_keyword || ip_cidr) && process_name
        To keep DOMAIN/IP and PROCESS-NAME as an OR (rule-set semantics), the
        process names are written to a *second* rule object. Rules inside a
        rule-set are OR-ed together.

    Note on domain_suffix:
        sing-box treats a suffix WITHOUT a leading dot (e.g. "google.com") as
        matching both the apex ("google.com") and any subdomain
        ("*.google.com"), which is exactly the Surge DOMAIN-SUFFIX semantic, so
        the value is passed through unchanged.

.PARAMETER SourceRoot
    Directory holding the Surge rules. Default: <repo>/rule/Surge

.PARAMETER OutputRoot
    Directory to write the sing-box rule-sets. Default: <repo>/rule/sing-box

.PARAMETER Version
    Rule-set source-format version to emit. Default: 3
        1 = sing-box 1.8.0+   2 = 1.10.0+   3 = 1.11.0+ (recommended, works on
        current alpha/beta and every 1.11+ release)   4 = 1.13.0+   5 = 1.14.0+
    Only domain/domain_suffix/domain_keyword/ip_cidr/process_name are produced,
    all of which exist since v1, so any value is valid; 3 is a safe modern default.

.PARAMETER Services
    Optional list of service folder names to convert (for testing). Empty = all.

.PARAMETER Compile
    Also compile every generated .json to .srs using the sing-box binary.

.PARAMETER SingBox
    Path/name of the sing-box executable used with -Compile. Default: "sing-box"

.EXAMPLE
    pwsh ./generate_singbox_ruleset.ps1
    powershell -ExecutionPolicy Bypass -File .\generate_singbox_ruleset.ps1 -Services Google,Netflix
    powershell -ExecutionPolicy Bypass -File .\generate_singbox_ruleset.ps1 -Compile
#>
[CmdletBinding()]
param(
    [string]  $SourceRoot,
    [string]  $OutputRoot,
    [ValidateRange(1, 5)]
    [int]     $Version = 3,
    [string[]]$Services = @(),
    [switch]  $Compile,
    [string]  $SingBox = 'sing-box'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Resolve the script directory robustly across invocation styles.
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $SourceRoot) { $SourceRoot = Join-Path $scriptDir 'rule\Surge' }
if (-not $OutputRoot) { $OutputRoot = Join-Path $scriptDir 'rule\sing-box' }

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Add-Unique {
    param(
        [System.Collections.Generic.HashSet[string]] $Seen,
        [System.Collections.Generic.List[string]]    $List,
        [string]                                      $Value
    )
    if ($Seen.Add($Value)) { [void]$List.Add($Value) }
}

function ConvertTo-JsonStringValue {
    param([string] $Value)
    # Domains/IPs never contain these, but escape defensively for keywords/names.
    return $Value.Replace('\', '\\').Replace('"', '\"')
}

function New-FieldBlock {
    # Returns the JSON text for one field array, or $null when empty.
    param(
        [string] $Name,
        [System.Collections.Generic.List[string]] $Values,
        [int]    $Indent
    )
    if ($Values.Count -eq 0) { return $null }
    $pad = ' ' * $Indent
    $pad2 = ' ' * ($Indent + 2)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($pad).Append('"').Append($Name).Append('": [').Append("`n")
    for ($i = 0; $i -lt $Values.Count; $i++) {
        [void]$sb.Append($pad2).Append('"').Append((ConvertTo-JsonStringValue $Values[$i])).Append('"')
        if ($i -lt $Values.Count - 1) { [void]$sb.Append(',') }
        [void]$sb.Append("`n")
    }
    [void]$sb.Append($pad).Append(']')
    return $sb.ToString()
}

function New-RuleObject {
    param(
        [System.Collections.Generic.List[string]] $Blocks,
        [int] $Indent
    )
    $pad = ' ' * $Indent
    return $pad + "{`n" + ($Blocks -join ",`n") + "`n" + $pad + "}"
}

function Convert-ListFile {
    param([string] $Path)

    $dSeen = New-Object 'System.Collections.Generic.HashSet[string]'; $domain  = New-Object 'System.Collections.Generic.List[string]'
    $sSeen = New-Object 'System.Collections.Generic.HashSet[string]'; $suffix  = New-Object 'System.Collections.Generic.List[string]'
    $kSeen = New-Object 'System.Collections.Generic.HashSet[string]'; $keyword = New-Object 'System.Collections.Generic.List[string]'
    $iSeen = New-Object 'System.Collections.Generic.HashSet[string]'; $ipcidr  = New-Object 'System.Collections.Generic.List[string]'
    $pSeen = New-Object 'System.Collections.Generic.HashSet[string]'; $process = New-Object 'System.Collections.Generic.List[string]'
    $skipped = 0

    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        $t = $line.Trim()
        if ($t.Length -eq 0 -or $t[0] -eq '#') { continue }

        $ci = $t.IndexOf(',')
        if ($ci -lt 0) {
            # Domain-set style entry (no type prefix).
            if ($t[0] -eq '.') { Add-Unique $sSeen $suffix $t.TrimStart('.') }
            else               { Add-Unique $dSeen $domain $t }
            continue
        }

        $type = $t.Substring(0, $ci)
        $rest = $t.Substring($ci + 1)
        $c2 = $rest.IndexOf(',')           # drop trailing options e.g. ",no-resolve"
        if ($c2 -ge 0) { $val = $rest.Substring(0, $c2).Trim() } else { $val = $rest.Trim() }
        if ($val.Length -eq 0) { continue }

        switch ($type) {
            'DOMAIN'         { Add-Unique $dSeen $domain  $val }
            'DOMAIN-SUFFIX'  { Add-Unique $sSeen $suffix  $val }
            'DOMAIN-KEYWORD' { Add-Unique $kSeen $keyword $val }
            'IP-CIDR'        { Add-Unique $iSeen $ipcidr  $val }
            'IP-CIDR6'       { Add-Unique $iSeen $ipcidr  $val }
            'PROCESS-NAME'   { Add-Unique $pSeen $process $val }
            default          { $skipped++ }
        }
    }

    return [pscustomobject]@{
        Domain  = $domain
        Suffix  = $suffix
        Keyword = $keyword
        IpCidr  = $ipcidr
        Process = $process
        Skipped = $skipped
        Total   = $domain.Count + $suffix.Count + $keyword.Count + $ipcidr.Count + $process.Count
    }
}

function Build-RuleSetJson {
    param($Data, [int] $Version)

    $rules = New-Object System.Collections.Generic.List[string]

    # Rule object #1: domain family + ip_cidr (OR-ed together by sing-box).
    $b1 = New-Object System.Collections.Generic.List[string]
    $blk = New-FieldBlock 'domain'         $Data.Domain  6; if ($blk) { [void]$b1.Add($blk) }
    $blk = New-FieldBlock 'domain_suffix'  $Data.Suffix  6; if ($blk) { [void]$b1.Add($blk) }
    $blk = New-FieldBlock 'domain_keyword' $Data.Keyword 6; if ($blk) { [void]$b1.Add($blk) }
    $blk = New-FieldBlock 'ip_cidr'        $Data.IpCidr  6; if ($blk) { [void]$b1.Add($blk) }
    if ($b1.Count -gt 0) { [void]$rules.Add((New-RuleObject $b1 4)) }

    # Rule object #2: process_name (kept separate so it OR-s with the above).
    $b2 = New-Object System.Collections.Generic.List[string]
    $blk = New-FieldBlock 'process_name'   $Data.Process 6; if ($blk) { [void]$b2.Add($blk) }
    if ($b2.Count -gt 0) { [void]$rules.Add((New-RuleObject $b2 4)) }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("{`n  `"version`": ").Append($Version).Append(",`n  `"rules`": [")
    if ($rules.Count -gt 0) {
        [void]$sb.Append("`n").Append(($rules -join ",`n")).Append("`n  ]`n}`n")
    }
    else {
        [void]$sb.Append("]`n}`n")
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $SourceRoot)) {
    throw "Source directory not found: $SourceRoot"
}
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
if (-not (Test-Path -LiteralPath $OutputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path

$compiler = $null
if ($Compile) {
    $compiler = Get-Command $SingBox -ErrorAction SilentlyContinue
    if (-not $compiler) {
        Write-Warning "sing-box executable '$SingBox' not found; .srs compilation skipped."
    }
}

Write-Host "Source : $SourceRoot"
Write-Host "Output : $OutputRoot"
Write-Host "Version: $Version"
Write-Host ""

$allFiles = Get-ChildItem -LiteralPath $SourceRoot -Recurse -Filter *.list -File |
    Where-Object { $_.Name -notlike '*_Resolve.list' }   # _Resolve == base minus no-resolve

if ($Services.Count -gt 0) {
    $set = [System.Collections.Generic.HashSet[string]]::new([string[]]$Services, [System.StringComparer]::OrdinalIgnoreCase)
    $allFiles = $allFiles | Where-Object {
        $rel = $_.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        $top = ($rel -split '[\\/]')[0]
        $set.Contains($top)
    }
}

$fileCount = 0; $emptyCount = 0; $ruleTotal = 0L; $skipTotal = 0L; $compiled = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($file in $allFiles) {
    $rel = $file.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
    $outPath = [System.IO.Path]::ChangeExtension((Join-Path $OutputRoot $rel), '.json')
    $outDir = Split-Path -Parent $outPath
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    $data = Convert-ListFile -Path $file.FullName
    $json = Build-RuleSetJson -Data $data -Version $Version
    [System.IO.File]::WriteAllText($outPath, $json, $utf8NoBom)

    $fileCount++
    $ruleTotal += $data.Total
    $skipTotal += $data.Skipped
    if ($data.Total -eq 0) { $emptyCount++ }

    if ($compiler) {
        $srs = [System.IO.Path]::ChangeExtension($outPath, '.srs')
        & $compiler.Source rule-set compile --output $srs $outPath 2>$null
        if ($LASTEXITCODE -eq 0) { $compiled++ }
    }

    if ($fileCount % 200 -eq 0) {
        Write-Host ("  {0,6} files... ({1:N0} rules)" -f $fileCount, $ruleTotal)
    }
}

$sw.Stop()
Write-Host ""
Write-Host "Done."
Write-Host ("  rule-sets written : {0}" -f $fileCount)
Write-Host ("  empty rule-sets   : {0}" -f $emptyCount)
Write-Host ("  rules emitted     : {0:N0}" -f $ruleTotal)
Write-Host ("  entries skipped   : {0:N0}  (IP-ASN / USER-AGENT / URL-REGEX / logical)" -f $skipTotal)
if ($compiler) { Write-Host ("  .srs compiled     : {0}" -f $compiled) }
Write-Host ("  elapsed           : {0:N1}s" -f $sw.Elapsed.TotalSeconds)
