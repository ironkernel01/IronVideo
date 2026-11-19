# SPDX-License-Identifier: GPL-2.0-only
[CmdletBinding()]
param(
    [ValidateSet('firmware','generate','build','embed')] [string]$Stage = 'build',
    [string]$AmdRoot = 'C:/AMDDesignTools/2026.1',
    [ValidateRange(1,32)] [int]$Jobs = 4,
    [string]$MigPrj,
    [string]$RouteReceipt,
    [switch]$Offline
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$amd = (Resolve-Path -LiteralPath $AmdRoot).Path
$build = Join-Path $root 'build/nexys-ref'
$id = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N').Substring(0,8)
$output = Join-Path $build $id
if (($Stage -eq 'embed') -ne [bool]$RouteReceipt -or ($Stage -eq 'embed' -and $MigPrj)) {
    throw 'Use -RouteReceipt with -Stage embed only. The routed receipt already binds the MIG input.'
}
New-Item -ItemType Directory -Path $output -Force | Out-Null
Write-Host "Nexys reference output in $output"

function Invoke-Native([string]$Tool, [string[]]$Arguments) {
    & $Tool @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Tool exited with code $LASTEXITCODE. Output in $output" }
}

$mb = Join-Path $amd 'gnu/microblaze/nt/bin'
$gcc = Join-Path $mb 'mb-gcc.exe'
$readelf = Join-Path $mb 'mb-readelf.exe'
$vivado = Join-Path $amd 'Vivado/bin/vivado.bat'
$updatemem = Join-Path $amd 'Vivado/bin/updatemem.bat'
$elf = Join-Path $output 'demo.elf'
$rawBit = Join-Path $output 'fpga.bit'
$memInfo = Join-Path $output 'fpga.mmi'
$inputs = @($PSCommandPath)
$tools = @()
$routePath = $null
$hardwareInputs = @('build.tcl','clocks.v','board.xdc','interface_timing.xdc' |
    ForEach-Object { Join-Path $PSScriptRoot $_ })
$routeInputs = @('video_cdc.tcl','qualify.tcl' | ForEach-Object { Join-Path $PSScriptRoot $_ })
$hdlInputs = @(Get-ChildItem -LiteralPath (Join-Path $root 'hdl') -File |
    Where-Object Extension -in '.v','.sv' | ForEach-Object FullName)
$expectedMig = '82122fb1a992c4c2c540f31068ab6a08fe4782552562051c4d7a7548698853f1'
function Assert-SealedFile([string]$File, $Manifest) {
    $path = (Resolve-Path -LiteralPath $File).Path
    $entry = $Manifest.PSObject.Properties[$path]
    if ($null -eq $entry -or (Get-FileHash -LiteralPath $path).Hash -ne $entry.Value) {
        throw "Routed receipt does not seal $path"
    }
    return $path
}

if ($Stage -ne 'generate') {
    $tools += $gcc, $readelf
    $inputs += @('start.S','link.ld','main.c','cube.c','cube.h','animation.c','animation.h' |
        ForEach-Object { Join-Path $PSScriptRoot $_ })
    $inputs += @(Join-Path $root 'driver/ironvideo_core.h'; Join-Path $root 'driver/ironvideo_regs.h')
}
if ($Stage -in 'generate','build') {
    $tools += $vivado
    $inputs += $hardwareInputs + $hdlInputs
    if ($Stage -eq 'build') {
        $tools += $updatemem
        $inputs += $routeInputs
    }
    if ($MigPrj) {
        $mig = (Resolve-Path -LiteralPath $MigPrj).Path
    } else {
        $cache = Join-Path $build 'inputs'
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        $mig = Join-Path $cache 'nexys-video-mig.prj'
        if (!(Test-Path -LiteralPath $mig -PathType Leaf)) {
            if ($Offline) { throw "Pinned MIG project missing: $mig" }
            $url = 'https://raw.githubusercontent.com/Digilent/vivado-boards/d8d43ed9f3f7e367ee3de82782ed601d88305677/new/board_files/nexys_video/A.0/1.2/mig.prj'
            $partial = Join-Path $cache "$id.partial"
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $partial
                if ((Get-FileHash -LiteralPath $partial).Hash -ne $expectedMig) {
                    throw 'Downloaded Nexys Video MIG project hash mismatch'
                }
                # A parallel acquisition may have already published the same blob.
                if (!(Test-Path -LiteralPath $mig -PathType Leaf)) { [IO.File]::Move($partial, $mig) }
            } finally {
                if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial }
            }
        }
    }
    if ((Get-FileHash -LiteralPath $mig).Hash -ne $expectedMig) { throw "Pinned MIG project hash mismatch: $mig" }
    $inputs += $mig
}
if ($Stage -eq 'embed') {
    $routePath = (Resolve-Path -LiteralPath $RouteReceipt).Path
    $route = Get-Content -LiteralPath $routePath -Raw | ConvertFrom-Json
    if ($route.result -cne 'PASS' -or $route.stage -cne 'build' -or
        $route.board -cne 'Nexys Video rev A' -or $route.mode -cne '720p60') {
        throw 'Embed requires a passing full route receipt for this Nexys reference design'
    }
    $inputs += $routePath
    foreach ($source in ($hardwareInputs + $routeInputs + $hdlInputs)) {
        $inputs += Assert-SealedFile $source $route.input_sha256
    }
    $mig = @($route.input_sha256.PSObject.Properties | Where-Object Value -eq $expectedMig)
    if ($mig.Count -ne 1) { throw 'Routed receipt does not identify exactly one pinned MIG source' }
    $inputs += Assert-SealedFile $mig[0].Name $route.input_sha256
    $routeDirectory = Split-Path -Parent $routePath
    $rawBit = Assert-SealedFile (Join-Path $routeDirectory 'fpga.bit') $route.output_sha256
    $memInfo = Assert-SealedFile (Join-Path $routeDirectory 'fpga.mmi') $route.output_sha256
    $inputs += $rawBit, $memInfo
    foreach ($name in 'vivado.log','timing.rpt','check_timing.rpt','bus_skew.rpt',
                      'cdc.rpt','clocks.rpt','drc.rpt','utilization.rpt') {
        $inputs += Assert-SealedFile (Join-Path $routeDirectory $name) $route.output_sha256
    }
    if (!(Select-String -LiteralPath (Join-Path $routeDirectory 'vivado.log') -Pattern '^NEXYS REFERENCE ROUTE PASS$')) {
        throw 'Routed log did not pass the native reference gate'
    }
    $tools += Assert-SealedFile $vivado $route.tool_sha256
    $tools += Assert-SealedFile $updatemem $route.tool_sha256
}

function Get-Manifest([string[]]$Paths) {
    $result = [ordered]@{}
    foreach ($file in $Paths) {
        $path = (Resolve-Path -LiteralPath $file).Path
        $result[$path] = (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
    }
    return $result
}
$inputHashes = Get-Manifest $inputs
$toolHashes = Get-Manifest $tools

Push-Location -LiteralPath $output
try {
    if ($Stage -ne 'generate') {
        Invoke-Native $gcc @('-mcpu=v11.0', '-mlittle-endian', '-mxl-barrel-shift',
            '-mxl-multiply-high', '-mno-xl-soft-mul', '-mno-xl-soft-div', '-G0', '-Os', '-std=c11',
            '-Wall', '-Wextra', '-Werror', '-ffreestanding', '-nostartfiles', '-nostdlib',
            "-I$root/driver", "-Wl,-T,$PSScriptRoot/link.ld,-Map,$output/demo.map",
            "$PSScriptRoot/start.S", "$PSScriptRoot/main.c", "$PSScriptRoot/cube.c", "$PSScriptRoot/animation.c", '-lgcc', '-o', $elf)
        Invoke-Native $readelf @('-hl', $elf) | Set-Content -LiteralPath 'elf.txt' -Encoding Ascii
        $info = Get-Content -LiteralPath 'elf.txt' -Raw
        if ($info -notmatch 'little endian' -or $info -notmatch 'MicroBlaze' -or
            $info -notmatch 'Entry point address:\s+0x0\s') { throw 'Unexpected Nexys demo ELF header' }
    }
    if ($Stage -in 'generate','build') {
        Invoke-Native $vivado @('-mode', 'batch', '-source', "$PSScriptRoot/build.tcl",
            '-tclargs', $root, $output, $mig, $Stage, $Jobs)
        $gate = if ($Stage -eq 'generate') { 'NEXYS REFERENCE BLOCK DESIGN PASS' } else { 'NEXYS REFERENCE ROUTE PASS' }
        if (!(Select-String -LiteralPath 'vivado.log' -SimpleMatch $gate)) { throw "Missing gate: $gate" }
    }
    if ($Stage -in 'build','embed') {
        [xml]$mmi = Get-Content -LiteralPath $memInfo -Raw
        $processor = @($mmi.MemInfo.Processor)
        if ($processor.Count -ne 1 -or !$processor[0].InstPath -or $processor[0].Endianness -ne 'Little') {
            throw 'Unexpected Nexys reference MMI processor'
        }
        Invoke-Native $updatemem @('-meminfo', $memInfo, '-data', $elf, '-bit', $rawBit,
            '-proc', $processor[0].InstPath, '-out', 'nexys-ironvideo-demo.bit')
        if ((Get-FileHash -LiteralPath $rawBit).Hash -eq
            (Get-FileHash -LiteralPath 'nexys-ironvideo-demo.bit').Hash) { throw 'BRAM firmware did not change bitstream' }
    }
    foreach ($manifest in $inputHashes,$toolHashes) {
        foreach ($file in $manifest.Keys) {
            if ((Get-FileHash -LiteralPath $file).Hash -ne $manifest[$file]) { throw "Build input changed: $file" }
        }
    }
    $outputs = @(Get-ChildItem -LiteralPath $output -File | ForEach-Object FullName)
    [ordered]@{
        result = 'PASS'
        stage = $Stage
        board = 'Nexys Video rev A'
        mode = '720p60'
        hardware_execution_verified = $false
        base_route_receipt = $routePath
        input_sha256 = $inputHashes
        tool_sha256 = $toolHashes
        output_sha256 = Get-Manifest $outputs
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath 'receipt.json' -Encoding UTF8
} finally {
    Pop-Location
}
Write-Host "Nexys reference $Stage passed. Receipt in $output/receipt.json"
