[CmdletBinding()]
param(
    [string] $VivadoBin = 'C:/AMDDesignTools/2026.1/Vivado/bin',
    [string] $IronForgeRoot
)

$ErrorActionPreference = 'Stop'
$VivadoBin = (Resolve-Path -LiteralPath $VivadoBin).Path
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
$vivadoRoot = Split-Path -Parent $VivadoBin
$vivadoData = Get-Item -LiteralPath (Join-Path $vivadoRoot 'data')
if ($vivadoData.Target) {
    $dataPath = $vivadoData.Target[0]
    if (-not [IO.Path]::IsPathRooted($dataPath)) {
        $dataPath = Join-Path $vivadoRoot $dataPath
    }
    $vivadoData = Get-Item -LiteralPath $dataPath
}
$runName = 'xsim-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N')
$runDirectory = Join-Path $outputRoot $runName
$sources = @('ironvideo_pkg', 'ironvideo_reset', 'ironvideo_fifo', 'ironvideo_reader', 'ironvideo_color', 'ironvideo_plane_bounds', 'ironvideo_raster',
    'ironvideo_row_stats', 'ironvideo_scanout')
$sources += @('ironvideo_tmds_encoder', 'ironvideo_tmds_lane_7series', 'ironvideo_tmds_7series', 'ironvideo_hdmi_7series')
$sources = $sources | ForEach-Object { Join-Path $PSScriptRoot "hdl/$_.sv" }
$sources += Join-Path $PSScriptRoot 'hdl/ironvideo_top.v'
$sources += @('ironvideo_format_model', 'tb_ironvideo', 'tb_ironvideo_formats', 'tb_ironvideo_reader_limits', 'tb_ironvideo_nv12_reader', 'tb_ironvideo_row_stats', 'tb_ironvideo_720p',
    'tb_ironvideo_tmds', 'tb_ironvideo_tmds_7series', 'tb_ironvideo_hdmi_7series', 'tb_ironvideo_clock_select') |
    ForEach-Object { Join-Path $PSScriptRoot "testbench/$_.sv" }
$sources += Join-Path $vivadoData.FullName 'verilog/src/glbl.v'
$toolPaths = @('xvlog.bat', 'xelab.bat', 'xsim.bat', 'setupEnv.bat', 'loader.bat',
    'unwrapped/win64.o/xvlog.exe', 'unwrapped/win64.o/xelab.exe', 'unwrapped/win64.o/xsim.exe') |
    ForEach-Object { Join-Path $VivadoBin $_ }
$toolPaths += Join-Path $vivadoData.FullName 'xsim/xsim.ini'
foreach ($library in @('unisims_ver', 'secureip')) {
    foreach ($extension in @('rlx', 'sdbx', 'sdbl')) {
        $toolPaths += Join-Path $vivadoData.FullName "xsim/verilog/$library/$library.$extension"
    }
}

function Get-Sha256 {
    param([string] $Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$inputs = [ordered]@{}
foreach ($source in @($PSCommandPath) + $sources) {
    $path = (Resolve-Path -LiteralPath $source).Path
    $inputs[$path] = Get-Sha256 $path
}
$tools = [ordered]@{}
foreach ($toolPath in $toolPaths) {
    $path = (Resolve-Path -LiteralPath $toolPath).Path
    $tools[$path] = Get-Sha256 $path
}
$results = [ordered]@{}
$logs = [ordered]@{}

function Invoke-Simulator {
    param([string] $Tool, [string[]] $Arguments)

    & (Join-Path $VivadoBin "$Tool.bat") @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Tool returned exit code $LASTEXITCODE. See $runDirectory"
    }
}

function Invoke-Regression {
    param([string] $Top, [string] $Pass, [string[]] $Libraries = @())

    $elaborateLog = "$Top-elaborate.log"
    $simulateLog = "$Top-simulate.log"
    Invoke-Simulator -Tool xelab -Arguments (@("work.$Top", '-s', $Top, '--log', $elaborateLog) + $Libraries)
    Invoke-Simulator -Tool xsim -Arguments @($Top, '--runall', '--log', $simulateLog)
    $passed = Select-String -LiteralPath $simulateLog -Pattern ('^' + [regex]::Escape($Pass) + '\s*$')
    $failed = Select-String -LiteralPath $simulateLog -Pattern '^\s*(?:TEST FAIL:|Fatal:|ERROR:)'
    if (@($passed).Count -ne 1 -or $failed) {
        throw "IronVideo regression $Top did not complete successfully. See $runDirectory/$simulateLog"
    }
    $results[$Top] = $Pass
    $logs[$elaborateLog] = Get-Sha256 $elaborateLog
    $logs[$simulateLog] = Get-Sha256 $simulateLog
}

New-Item -ItemType Directory -Path $runDirectory | Out-Null
Write-Host "IronVideo simulation artifacts are in $runDirectory"
Push-Location -LiteralPath $runDirectory
try {
    Invoke-Simulator -Tool xvlog -Arguments (@('--sv', '--log', 'compile.log') + $sources)
    $logs['compile.log'] = Get-Sha256 'compile.log'
    $unisim = @('work.glbl', '-L', 'unisims_ver', '-L', 'secureip')
    Invoke-Regression -Top tb_ironvideo_clock_select -Pass 'TEST PASS: IronVideo software clock selection, both clock pairs and active scanout interlock' -Libraries $unisim
    Invoke-Regression -Top tb_ironvideo -Pass 'TEST PASS: IronVideo 32/64/128-bit regression' -Libraries $unisim
    Invoke-Regression -Top tb_ironvideo_reader_limits -Pass 'TEST PASS: IronVideo reader burst limits'
    Invoke-Regression -Top tb_ironvideo_nv12_reader -Pass 'TEST PASS: IronVideo NV12 reader widths, chroma reuse, packing and drain'
    Invoke-Regression -Top tb_ironvideo_formats -Pass 'TEST PASS: IronVideo all 15 format masks, live DDR pixels, plane bounds and row telemetry'
    Invoke-Regression -Top tb_ironvideo_row_stats -Pass 'TEST PASS: IronVideo row fetch statistics'
    Invoke-Regression -Top tb_ironvideo_720p -Pass 'TEST PASS: IronVideo 720p60 full frame'
    Invoke-Regression -Top tb_ironvideo_720p_128 -Pass 'TEST PASS: IronVideo 720p60 128-bit full frame'
    Invoke-Regression -Top tb_ironvideo_720p_128_burst32 -Pass 'TEST PASS: IronVideo 720p60 128-bit full frame with 32-beat bursts'
    Invoke-Regression -Top tb_ironvideo_tmds -Pass 'TEST PASS: IronVideo TMDS encoder regression'
    Invoke-Regression -Top tb_ironvideo_tmds_7series -Pass 'TEST PASS: IronVideo 7-series TMDS serialization' -Libraries $unisim
    Invoke-Regression -Top tb_ironvideo_hdmi_7series -Pass 'TEST PASS: IronVideo AXI-to-TMDS top' -Libraries $unisim

    foreach ($manifest in @($inputs, $tools)) {
        foreach ($path in $manifest.Keys) {
            if ((Get-Sha256 $path) -cne $manifest[$path]) {
                throw "Simulation input changed during the run: $path"
            }
        }
    }
    $version = @(Select-String -LiteralPath 'tb_ironvideo-simulate.log' -Pattern '^# (xsim v|(SW|IP|SharedData) Build )' |
        ForEach-Object { $_.Line.Substring(2).Trim() })
    if ($version.Count -ne 4) {
        throw "Could not identify the Vivado simulator build. See $runDirectory"
    }
    $receipt = [ordered]@{
        schema = 1
        run_id = $runName
        result = 'PASS'
        simulator = $version
        gates = $results
        input_sha256 = $inputs
        tool_sha256 = $tools
        log_sha256 = $logs
    }
    $encoding = [Text.UTF8Encoding]::new($false)
    $json = ($receipt | ConvertTo-Json -Depth 6) + [Environment]::NewLine
    $positiveReceipt = Join-Path $runDirectory 'receipt.json'
    [IO.File]::WriteAllText($positiveReceipt, $json, $encoding)
    Write-Host "IronVideo regression passed. Receipt in $positiveReceipt"

    $familyLog = 'tb_ironvideo_unsupported_family-elaborate.log'
    & (Join-Path $VivadoBin 'xelab.bat') 'work.tb_ironvideo_unsupported_family' '--log' $familyLog @unisim
    $familyError = 'ERROR: .*\bIRONVIDEO_UNSUPPORTED_FAMILY__USE_7SERIES\b'
    if ($LASTEXITCODE -eq 0 -or !(Select-String -LiteralPath $familyLog -Pattern $familyError)) {
        throw "IronVideo did not reject the unsupported FAMILY at elaboration. See $runDirectory/$familyLog"
    }
    $familyReceipt = [ordered]@{
        schema = 1
        run_id = $runName
        family = 'ULTRASCALE'
        result = 'EXPECTED ELABORATION REJECTION'
        positive_receipt_sha256 = Get-Sha256 $positiveReceipt
        log_sha256 = @{ $familyLog = Get-Sha256 $familyLog }
    }
    $familyJson = ($familyReceipt | ConvertTo-Json -Depth 3) + [Environment]::NewLine
    [IO.File]::WriteAllText((Join-Path $runDirectory 'family-rejection.json'), $familyJson, $encoding)
    Write-Host "Unsupported FAMILY rejected. Receipt in $runDirectory/family-rejection.json"

    $maskLogs = [ordered]@{}
    foreach ($top in 'tb_ironvideo_zero_mask', 'tb_ironvideo_unknown_mask') {
        $log = "$top-elaborate.log"
        & (Join-Path $VivadoBin 'xelab.bat') "work.$top" '--log' $log
        if ($LASTEXITCODE -eq 0 -or !(Select-String -LiteralPath $log -Pattern 'ERROR: .*\bIRONVIDEO_FORMAT_MASK_MUST_BE_1_TO_15\b')) {
            throw "Malformed FORMAT_MASK was not rejected by $top. See $runDirectory/$log"
        }
        $maskLogs[$log] = Get-Sha256 $log
    }
    $maskReceipt = [ordered]@{
        run_id = $runName
        result = 'EXPECTED ELABORATION REJECTION'
        positive_receipt_sha256 = Get-Sha256 $positiveReceipt
        log_sha256 = $maskLogs
    }
    [IO.File]::WriteAllText((Join-Path $runDirectory 'format-mask-rejection.json'),
        ($maskReceipt | ConvertTo-Json -Depth 6), $encoding)
    Write-Host "Invalid FORMAT_MASK values rejected. Receipt in $runDirectory/format-mask-rejection.json"
}
finally {
    Pop-Location
}
