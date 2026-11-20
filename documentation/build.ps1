[CmdletBinding()]
param([string] $IronForgeRoot)

$ErrorActionPreference = 'Stop'
if (!$IronForgeRoot) {
    $IronForgeRoot = Join-Path $PSScriptRoot '../../..'
    if (!(Test-Path -LiteralPath (Join-Path $IronForgeRoot 'IRONFORGE.md'))) {
        $IronForgeRoot = Join-Path $PSScriptRoot '../../IronForge'
    }
}
$toolRoot = (Resolve-Path -LiteralPath $IronForgeRoot).Path
$renderer = Join-Path $toolRoot 'documentation/build_pdf.ps1'
$validator = Join-Path $toolRoot 'documentation/pdf/validate.ps1'
$core = Split-Path -Parent $PSScriptRoot

$name = 'ironvideo_specification'
$source = Join-Path $PSScriptRoot "$name.md"
$pdf = Join-Path $PSScriptRoot "$name.pdf"
& $renderer -Name $name -Source $source -Output $pdf
$preview = Join-Path $core "build/documentation/$name"
& $validator -Pdf $pdf -OutputDirectory $preview
$expectedUrls = @('https://ironkernel.com/', 'mailto:support@ironkernel.com')
$urls = @(Get-Content -LiteralPath (Join-Path $preview 'links.txt') | Select-Object -Skip 1 |
    ForEach-Object { ($_.Trim() -split '\s+', 3)[2] } | Sort-Object -Unique)
if (Compare-Object $expectedUrls $urls) { throw "Unexpected contact link inventory in $pdf" }
