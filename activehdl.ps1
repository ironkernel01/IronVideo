[CmdletBinding()]
param(
    [string] $AldecBin = 'C:/Aldec/Active-HDL-11.1-x64/bin',
    [string] $VivadoData = 'C:/AMDDesignTools/2026.1/data',
    [string] $IronForgeRoot,
    [ValidateSet('XRGB8888','RGB565','YUV422','YUV420')]
    [string] $PixelFormat = 'XRGB8888'
)

$ErrorActionPreference = 'Stop'
$AldecBin = (Resolve-Path -LiteralPath $AldecBin).Path
$VivadoData = (Resolve-Path -LiteralPath $VivadoData).Path
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
$runName = 'activehdl-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N')
$output = Join-Path $outputRoot $runName
$secureIP = @('secureip/oserdese2/oserdese2_001.vp', 'secureip/oserdese2/oserdese2_002.vp') |
    ForEach-Object { Join-Path $VivadoData $_ }
$vendorVerilog = @('OSERDESE2', 'OBUFDS') | ForEach-Object { Join-Path $VivadoData "verilog/src/unisims/$_.v" }
$rtl = @('ironvideo_pkg', 'ironvideo_reset', 'ironvideo_fifo', 'ironvideo_reader', 'ironvideo_color', 'ironvideo_plane_bounds', 'ironvideo_raster',
    'ironvideo_row_stats', 'ironvideo_scanout', 'ironvideo_tmds_encoder', 'ironvideo_tmds_lane_7series',
    'ironvideo_tmds_7series', 'ironvideo_hdmi_7series') |
    ForEach-Object { Join-Path $PSScriptRoot "hdl/$_.sv" }
$rtl += Join-Path $PSScriptRoot 'hdl/ironvideo_top.v'
$testbenches = @('ironvideo_format_model', 'ironvideo_serial_receiver', 'tb_ironvideo_720p', 'tb_ironvideo_720p_serial', 'tb_ironvideo_1080p_serial') |
    ForEach-Object { Join-Path $PSScriptRoot "testbench/$_.sv" }
$glbl = Join-Path $VivadoData 'verilog/src/glbl.v'
$tops = @('tb_ironvideo_720p_serial', 'tb_ironvideo_1080p_serial')
$formatId = @('XRGB8888','RGB565','YUV422','YUV420').IndexOf($PixelFormat.ToUpperInvariant())

function Get-Manifest([string[]] $Paths) {
    $entries = [ordered]@{}
    foreach ($source in $Paths) {
        $path = (Resolve-Path -LiteralPath $source).Path
        $entries[$path] = (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
    }
    return $entries
}

function Invoke-Aldec([string] $Tool, [string] $Log, [string[]] $Arguments) {
    # Use stdout/stderr redirection outside PowerShell's native error wrapper.
    $executable = Join-Path $AldecBin "$Tool.exe"
    $quoted = $Arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }
    $proc = Start-Process -FilePath $executable -ArgumentList $quoted -WindowStyle Hidden -Wait -PassThru `
        -WorkingDirectory $output `
        -RedirectStandardOutput (Join-Path $output "$Log.log") `
        -RedirectStandardError (Join-Path $output "$Log.stderr.log")
    if ($proc.ExitCode -ne 0) {
        throw "$Tool returned exit code $($proc.ExitCode). See $output/$Log.log"
    }
}

function Get-GateResults([string] $Transcript) {
    $results = [ordered]@{}
    foreach ($mode in @(720, 1080)) {
        $gate = "$($mode)p60"
        $section = [regex]::Match($Transcript, "(?ms)^asim [^\r\n]*tb_ironvideo_$($mode)p_serial[^\r\n]*\r?\n(.*?)(?=^asim |\z)")
        $pass = "TEST PASS: IronVideo continuous serialized $gate with 32-beat bursts"
        $expectedWords = if ($mode -eq 720) { 3712501 } else { 7425001 }
        $outputText = $section.Groups[1].Value
        $results[$gate] = if (!$section.Success) {
            'NOT RUN'
        } elseif ($outputText.Contains("Checking native framebuffer format $formatId at $gate") -and
            [regex]::Matches($outputText, [regex]::Escape($pass)).Count -eq 1 -and
            [regex]::Matches($outputText, "$expectedWords serialized TMDS words verified").Count -eq 1 -and
            $outputText -notmatch '(?im)TEST FAIL:|^\s*(?:KERNEL:\s*)?(?:FATAL|ERROR)\b') {
            'PASS'
        } else {
            'FAIL'
        }
    }
    return $results
}

$inputs = Get-Manifest (@($PSCommandPath, $glbl) + $secureIP + $vendorVerilog + $rtl + $testbenches)
$tools = Get-Manifest (@('vlib', 'vlog', 'VSimSA') | ForEach-Object { Join-Path $AldecBin "$_.exe" })
$simulator = (Get-Item -LiteralPath (Join-Path $AldecBin 'VSimSA.exe')).VersionInfo.ProductVersion
$aldecLibraries = Join-Path (Split-Path -Parent $AldecBin) 'vlib'
$builtinFiles = @((Join-Path $aldecLibraries 'Library.cfg'))
foreach ($library in @('ieee', 'std', 'synopsys')) {
    $builtinFiles += @(Get-ChildItem -LiteralPath (Join-Path $aldecLibraries $library) -Recurse -File |
        ForEach-Object FullName)
}
$builtinLibraries = Get-Manifest $builtinFiles
$gates = [ordered]@{ '720p60' = 'NOT RUN'; '1080p60' = 'NOT RUN' }
$result = 'FAIL'
$failure = $null
New-Item -ItemType Directory -Path $output | Out-Null
Write-Host "Active-HDL output: $output"
Push-Location -LiteralPath $output
try {
    Invoke-Aldec vlib create-work @('work')
    Invoke-Aldec vlib create-unisims-ver @('unisims_ver')
    Invoke-Aldec vlib create-secureip @('secureip')
    Invoke-Aldec vlog compile-secureip (@('-v2k5', '-work', 'secureip') + $secureIP)
    Invoke-Aldec vlog compile-primitives (@('-v2k5', '-work', 'unisims_ver') + $vendorVerilog)
    Invoke-Aldec vlog compile-ironvideo (@('-sv2k12', '-work', 'work', $glbl) + $rtl + $testbenches)

    $macro = @('onerror {quit -code 1}')
    foreach ($top in $tops) {
        $macro += "asim -t 1fs -L unisims_ver -L secureip -gFORMAT_ID=$formatId work.$top work.glbl"
        $macro += 'run -all'
        $macro += 'endsim'
    }
    $macro += 'quit'
    Set-Content -LiteralPath 'run.do' -Value $macro -Encoding Ascii
    Invoke-Aldec VSimSA simulator @('-l', 'simulation.log', '-do', 'run.do')

    $gates = Get-GateResults (Get-Content -LiteralPath 'simulation.log' -Raw)
    if ($gates.Values -contains 'FAIL' -or $gates.Values -contains 'NOT RUN') {
        throw "Active-HDL HDMI regressions failed. See $output/simulation.log"
    }
    foreach ($manifest in @($inputs, $tools, $builtinLibraries)) {
        foreach ($path in $manifest.Keys) {
            if ((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $manifest[$path]) {
                throw "Simulation input changed: $path"
            }
        }
    }
    $result = 'PASS'
}
catch {
    $failure = $_.Exception.Message
    if (Test-Path -LiteralPath 'simulation.log') {
        $gates = Get-GateResults (Get-Content -LiteralPath 'simulation.log' -Raw)
    }
    throw
}
finally {
    $logs = Get-Manifest @(Get-ChildItem -File -Filter '*.log' | ForEach-Object FullName)
    $generatedLibraries = Get-Manifest @(Get-ChildItem unisims_ver, secureip -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object FullName)
    $receipt = [ordered]@{
        schema = 1
        run_id = $runName
        result = $result
        failure = $failure
        simulator = $simulator
        gates = $gates
        pixel_format = $PixelFormat
        input_sha256 = $inputs
        tool_sha256 = $tools
        builtin_library_sha256 = $builtinLibraries
        compiled_vendor_library_sha256 = $generatedLibraries
        log_sha256 = $logs
    }
    $receipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath 'receipt.json' -Encoding UTF8
    Pop-Location
}
Write-Host "Active-HDL HDMI regressions passed. Receipt: $output/receipt.json"
