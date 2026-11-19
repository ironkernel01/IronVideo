[CmdletBinding()]
param([string] $IronForgeRoot)

$ErrorActionPreference = 'Stop'
if (!$IronForgeRoot) { $IronForgeRoot = Join-Path $PSScriptRoot '../../IronForge' }
$toolRoot = (Resolve-Path -LiteralPath $IronForgeRoot).Path
$renderer = Join-Path $toolRoot 'documentation/build_pdf.ps1'
$validator = Join-Path $toolRoot 'documentation/pdf/validate.ps1'
$core = Split-Path -Parent $PSScriptRoot

foreach ($name in 'iron_brief', 'ironvideo_specification') {
    $source = Join-Path $PSScriptRoot "$name.md"
    $pdf = Join-Path $PSScriptRoot "$name.pdf"
    & $renderer -Name $name -Source $source -Output $pdf
    $preview = Join-Path $core "build/documentation/$name"
    & $validator -Pdf $pdf -OutputDirectory $preview
    $urls = @(Get-Content -LiteralPath (Join-Path $preview 'links.txt') | Select-Object -Skip 1)
    if ($urls.Count) { throw "Unexpected clickable links in $pdf" }
}
