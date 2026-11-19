[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PositiveReceipt,
    [string] $AldecBin = 'C:/Aldec/Active-HDL-11.1-x64/bin',
    [string] $IronForgeRoot
)

$ErrorActionPreference = 'Stop'
$outputRoot = Join-Path $PSScriptRoot 'build'
if (!$IronForgeRoot -and $PSScriptRoot -match '[\\/]rtl[\\/]ironvideo(?:[\\/]sources[\\/]ironvideo)?$') {
    $candidate = $PSScriptRoot -replace 'rtl[\\/]ironvideo(?:[\\/]sources[\\/]ironvideo)?$', ''
    if (Test-Path -LiteralPath (Join-Path $candidate 'IRONFORGE.md') -PathType Leaf) {
        $IronForgeRoot = $candidate
    }
}
if ($IronForgeRoot) {
    $IronForgeRoot = (Resolve-Path -LiteralPath $IronForgeRoot).Path
    if (!(Test-Path -LiteralPath (Join-Path $IronForgeRoot 'IRONFORGE.md') -PathType Leaf)) {
        throw "IronForge workspace required: $IronForgeRoot"
    }
    $outputRoot = Join-Path $IronForgeRoot 'build/ironvideo'
}
$positivePath = (Resolve-Path -LiteralPath $PositiveReceipt).Path
$positive = Get-Content -LiteralPath $positivePath -Raw | ConvertFrom-Json
if ($positive.result -ne 'PASS' -or $positive.gates.'720p60' -ne 'PASS' -or $positive.gates.'1080p60' -ne 'PASS') {
    throw 'Provide the completed two-mode Active-HDL positive receipt.'
}
$vSim = (Resolve-Path -LiteralPath (Join-Path $AldecBin 'VSimSA.exe')).Path
$proofHashes = @($positive.input_sha256.PSObject.Properties) + @($positive.tool_sha256.PSObject.Properties) +
    @($positive.builtin_library_sha256.PSObject.Properties)
foreach ($entry in $proofHashes) {
    if ((Get-FileHash -LiteralPath $entry.Name).Hash.ToLowerInvariant() -cne $entry.Value) {
        throw "Positive-run input changed: $($entry.Name)"
    }
}
if (!(($positive.tool_sha256.PSObject.Properties).Name -contains $vSim)) {
    throw 'The negative control requires the same native simulator as the positive run.'
}

$paths = @($positive.input_sha256.PSObject.Properties.Name)
$positiveRunner = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'activehdl.ps1')).Path
if ($positiveRunner -notin $paths) {
    throw 'The negative control requires a positive receipt from this checkout. Invoke both runners through the same path.'
}
$secure = $paths -match '[\\/]secureip[\\/]oserdese2[\\/].+\.vp$'
$verilog = $paths -match '[\\/]verilog[\\/]src[\\/]unisims[\\/].+\.v$'
$rtl = $paths -match '[\\/]glbl\.v$|[\\/](hdl|testbench)[\\/].+\.s?v$'
$negativeTop = 'tb_ironvideo_tmds_reversed_clock'
$negativeSource = Join-Path $PSScriptRoot "testbench/$negativeTop.sv"
$runName = 'activehdl-negative-clock-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N')
$output = Join-Path $outputRoot $runName
# Before mode commit, idle H/V are both high (the reset polarities are low).
# The half-word rotation takes CTL0 0x354 to 0x29a and blue CTL3 0x2ab to 0x175.
$syndrome = 'TEST FAIL: TMDS frame 0 pixel (0,0), RGB symbols 29a/29a/175 expected RGB 000000'
$macro = @(
    'onerror {quit -code 1}',
    "asim -t 1fs -L unisims_ver -L secureip work.$negativeTop work.glbl",
    'run -all', 'quit'
)

function Invoke-Native([string] $Tool, [string] $Log, [string[]] $Arguments) {
    $executable = Join-Path (Split-Path -Parent $vSim) "$Tool.exe"
    $quoted = $Arguments | ForEach-Object { '"' + $_ + '"' }
    Start-Process -FilePath $executable -ArgumentList $quoted -WindowStyle Hidden `
        -WorkingDirectory $output -Wait -PassThru -RedirectStandardOutput (Join-Path $output "$Log.log") `
        -RedirectStandardError (Join-Path $output "$Log.stderr.log")
}

function Invoke-Compiler([string] $Tool, [string] $Log, [string[]] $Arguments) {
    $compiler = Invoke-Native $Tool $Log $Arguments
    if ($compiler.ExitCode -ne 0) { throw "$Tool failed. See $output/$Log.log" }
}

New-Item -ItemType Directory -Path $output | Out-Null
foreach ($library in 'work', 'unisims_ver', 'secureip') {
    Invoke-Compiler vlib "create-$library" @($library)
}
Invoke-Compiler vlog compile-secureip (@('-v2k5', '-work', 'secureip') + $secure)
Invoke-Compiler vlog compile-primitives (@('-v2k5', '-work', 'unisims_ver') + $verilog)
Invoke-Compiler vlog compile-ironvideo (@('-sv2k12', '-work', 'work') + $rtl + $negativeSource)
Set-Content -LiteralPath (Join-Path $output 'run.do') -Value $macro -Encoding Ascii
$proc = Invoke-Native VSimSA simulator @('-l', 'simulation.log', '-do', 'run.do')
$logPath = Join-Path $output 'simulation.log'
$log = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw } else { '' }
$assertion = [regex]::Match($log, 'Time: ([0-9]+) fs,.*Instance: /tb_ironvideo_tmds_reversed_clock/reversed_clock_receiver,')
$rejected = [regex]::Matches($log, [regex]::Escape($syndrome), 'IgnoreCase').Count -eq 1 -and
    [regex]::Matches($log, 'TEST FAIL:', 'IgnoreCase').Count -eq 1 -and
    $assertion.Success -and $log -notmatch 'NEGATIVE CONTROL FAIL:'
$hashes = [ordered]@{}
foreach ($file in @($PSCommandPath, $negativeSource, $positivePath) +
    @(Get-ChildItem -LiteralPath $output -File | Where-Object Extension -in '.do', '.log' | ForEach-Object FullName)) {
    $hashes[$file] = (Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant()
}
$receipt = [ordered]@{
    schema = 1
    run_id = $runName
    result = if ($rejected) { 'EXPECTED REJECTION' } else { 'FAIL' }
    expected_syndrome = $syndrome
    receiver_assertion_time_fs = if ($assertion.Success) { [int64]$assertion.Groups[1].Value } else { $null }
    simulator_exit_code = $proc.ExitCode
    artifact_sha256 = $hashes
}
$receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'receipt.json') -Encoding UTF8
if (!$rejected) { throw "Clock polarity negative control did not produce the expected rejection. See $output" }
Write-Host "Reversed TMDS clock rejected at the expected receiver check. Receipt: $output/receipt.json"
