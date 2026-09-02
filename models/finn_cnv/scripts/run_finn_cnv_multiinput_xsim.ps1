[CmdletBinding()]
param(
    [ValidateSet('Gate1', 'Gate2', 'Full')]
    [string]$Through = 'Full',
    [switch]$RegenerateVectors,
    [string]$PythonExe = 'C:\Project_V2\BNN\.venv_cnv\Scripts\python.exe',
    [string]$RiscvBin = 'C:\Users\AERO\Downloads\project\학부연구생\RV32I_Single_Cycle_CPU\rv32imac (source)\bin',
    [string]$VivadoBin = 'C:\Xilinx\Vivado\2019.1\bin'
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModelDir = (Resolve-Path -LiteralPath (Join-Path $ScriptDir '..')).Path
$RepositoryRoot = (Resolve-Path -LiteralPath (Join-Path $ModelDir '..\..')).Path
$HardwareDir = Join-Path $RepositoryRoot 'hardware\wide_bdot128'
$SoftwareDir = Join-Path $ModelDir 'software\cnv'
$VectorsDir = Join-Path $ModelDir 'vectors\generated\multiinput'
$ResultsDir = Join-Path $ModelDir 'results'
$LogsDir = Join-Path $ModelDir 'logs\xsim2019_1'
$CaseLogsDir = Join-Path $LogsDir 'cases'
$CompileLogsDir = Join-Path $LogsDir 'compile'
$MemoryGateDir = Join-Path $LogsDir 'memory_gates'
$WorkDir = Join-Path $ModelDir 'work\xsim2019_1'
$MemDir = Join-Path $WorkDir 'mem'
$FirmwareRoot = Join-Path $ModelDir 'work\firmware'

function Assert-LastExitCode([string]$Step) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE"
    }
}

function Get-ResultFields([string]$Line) {
    $fields = @{}
    foreach ($token in ($Line -split '\s+')) {
        if ($token -match '^([^=]+)=(.*)$') {
            $fields[$Matches[1]] = $Matches[2]
        }
    }
    return $fields
}

function Convert-ResultLineToRow([string]$Line) {
    $fields = Get-ResultFields $Line
    return [pscustomobject][ordered]@{
        model = $fields.model
        sample_id = [int]$fields.sample_id
        dataset_index = [int]$fields.dataset_index
        ground_truth_label = [int]$fields.ground_truth_label
        expected_prediction = [int]$fields.expected_prediction
        actual_prediction = [int]$fields.actual_prediction
        prediction_match = $fields.prediction_match
        score_match = $fields.score_match
        checksum_match = $fields.checksum_match
        checksum_count = 10
        cycles = [int]$fields.cycles
        bdot_count = [int]$fields.bdot_count
        block_count = [int]$fields.block_count
        status = [int]$fields.status
        result = $fields.result
    }
}

function Normalize-VerilogWordAddresses([string]$Path) {
    $normalized = foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^@([0-9a-fA-F]+)(.*)$') {
            $byteAddress = [Convert]::ToUInt64($Matches[1], 16)
            if (($byteAddress % 4) -ne 0) {
                throw "Unaligned Verilog byte address in ${Path}: $line"
            }
            '@{0:X8}{1}' -f [uint64]($byteAddress / 4), $Matches[2]
        } else {
            $line
        }
    }
    $normalized | Set-Content -LiteralPath $Path -Encoding ascii
}

function Read-VerilogWordImage([string]$Path) {
    $words = @{}
    [uint64]$address = 0
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        foreach ($token in ($line.Trim() -split '\s+')) {
            if (-not $token) { continue }
            if ($token -match '^@([0-9a-fA-F]+)$') {
                $address = [Convert]::ToUInt64($Matches[1], 16)
            } elseif ($token -match '^[0-9a-fA-F]{8}$') {
                $words['{0:X8}' -f $address] = [Convert]::ToUInt32($token, 16)
                $address += 1
            }
        }
    }
    return $words
}

function Get-HeaderArray([string]$Text, [string]$Name) {
    $pattern = "(?s)\b$([regex]::Escape($Name))\s*\[[^\]]*\][^=;]*=\s*\{(.*?)\}\s*;"
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { throw "Header array was not found: $Name" }
    return @([regex]::Matches($match.Groups[1].Value, '-?0x[0-9a-fA-F]+|-?\d+') | ForEach-Object {
        $token = $_.Value
        $negative = $token.StartsWith('-')
        if ($negative) { $token = $token.Substring(1) }
        if ($token.StartsWith('0x')) {
            [int64]$value = [Convert]::ToInt64($token.Substring(2), 16)
        } else {
            [int64]$value = [Convert]::ToInt64($token, 10)
        }
        if ($negative) { -$value } else { $value }
    })
}

function Get-SymbolAddress([string[]]$NmOutput, [string]$Name) {
    $line = @($NmOutput | Where-Object { $_ -match "^([0-9a-fA-F]+)\s+\S\s+$([regex]::Escape($Name))$" })
    if ($line.Count -ne 1) { throw "Expected one symbol named $Name, found $($line.Count)" }
    $null = $line[0] -match '^([0-9a-fA-F]+)'
    return [Convert]::ToUInt64($Matches[1], 16)
}

function Assert-DmemWord(
    [hashtable]$Image,
    [uint64]$AbsoluteAddress,
    [uint32]$Expected,
    [string]$Name
) {
    if ($AbsoluteAddress -lt 0x20000000 -or (($AbsoluteAddress - 0x20000000) % 4) -ne 0) {
        throw "Unexpected DMEM symbol address for ${Name}: 0x$('{0:X8}' -f $AbsoluteAddress)"
    }
    $wordIndex = ($AbsoluteAddress - 0x20000000) / 4
    $key = '{0:X8}' -f $wordIndex
    if (-not $Image.ContainsKey($key)) { throw "DMEM image does not contain $Name at word index $key" }
    if ([uint32]$Image[$key] -ne $Expected) {
        throw "DMEM $Name mismatch at $key expected=$('{0:X8}' -f $Expected) actual=$('{0:X8}' -f [uint32]$Image[$key])"
    }
    return "DMEM_GATE PASS symbol=$Name address=0x$('{0:X8}' -f $AbsoluteAddress) word_index=$key value=$('{0:X8}' -f $Expected)"
}

function Copy-MemoryFile([string]$Source, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "Memory source is missing: $Source" }
    Copy-Item -LiteralPath $Source -Destination (Join-Path $MemDir $Name) -Force
}

function Build-FirmwareCase([int]$SampleId) {
    $caseName = 'case_{0:D2}' -f $SampleId
    $caseDir = Join-Path $VectorsDir $caseName
    $caseHeader = Join-Path $caseDir 'generated\cnv_bdot_params.h'
    $buildDir = Join-Path $FirmwareRoot $caseName
    $stageSoftwareDir = Join-Path $WorkDir "stage\$caseName\software"
    $stageCnvDir = Join-Path $stageSoftwareDir 'cnv'
    New-Item -ItemType Directory -Force -Path (Join-Path $stageCnvDir 'generated'), $buildDir | Out-Null

    Copy-Item -LiteralPath (Join-Path $SoftwareDir 'main_finn_cnv_bdot.c') -Destination (Join-Path $stageCnvDir 'main_finn_cnv_bdot.c') -Force
    Copy-Item -LiteralPath (Join-Path $ModelDir 'software\bdot.h') -Destination (Join-Path $stageSoftwareDir 'bdot.h') -Force
    Copy-Item -LiteralPath $caseHeader -Destination (Join-Path $stageCnvDir 'generated\cnv_bdot_params.h') -Force

    $elf = Join-Path $buildDir 'finn_cnv_bdot128.elf'
    $map = Join-Path $buildDir 'finn_cnv_bdot128.map'
    $asm = Join-Path $buildDir 'finn_cnv_bdot128.asm'
    $nmFile = Join-Path $buildDir 'finn_cnv_bdot128.nm'
    $imem = Join-Path $buildDir 'imem.hex'
    $dmem = Join-Path $buildDir 'dmem.hex'
    $gccArgs = @(
        '-march=rv32i', '-mabi=ilp32', '-O2', '-g0',
        '-ffunction-sections', '-fdata-sections', '-fno-builtin', '-nostdlib',
        "-I$stageCnvDir", '-Wl,--gc-sections', "-Wl,-Map,$map", '-T', (Join-Path $SoftwareDir 'memory_bdot.ld'),
        (Join-Path $ModelDir 'baseline\RISC-V\crt0.S'),
        (Join-Path $stageCnvDir 'main_finn_cnv_bdot.c'),
        (Join-Path $ModelDir 'software\rv32i_mulsi3.S'), '-lgcc', '-o', $elf
    )
    $buildOutput = & $script:GccExe @gccArgs 2>&1
    $buildExit = $LASTEXITCODE
    $buildOutput | Set-Content -LiteralPath (Join-Path $buildDir 'firmware_build.log') -Encoding utf8
    if ($buildExit -ne 0) { throw "RISC-V firmware build failed for $caseName" }
    & $script:SizeExe $elf | Set-Content -LiteralPath (Join-Path $buildDir 'firmware_size.log') -Encoding ascii
    Assert-LastExitCode "RISC-V size $caseName"
    $objdumpOutput = @(& $script:ObjdumpExe -d $elf 2>&1)
    Assert-LastExitCode "RISC-V objdump $caseName"
    $objdumpOutput | Set-Content -LiteralPath $asm -Encoding ascii
    $compressedInstructions = @($objdumpOutput | Where-Object { $_ -match '^\s*[0-9a-fA-F]+:\s+[0-9a-fA-F]{4}\s+' })
    if ($compressedInstructions.Count -ne 0) {
        throw "RV32I ISA gate failed for ${caseName}: compressed instruction found: $($compressedInstructions[0])"
    }
    $nmOutput = @(& $script:NmExe -n $elf 2>&1)
    Assert-LastExitCode "RISC-V nm $caseName"
    $nmOutput | Set-Content -LiteralPath $nmFile -Encoding ascii
    & $script:ObjcopyExe -O verilog --verilog-data-width=4 --reverse-bytes=4 -j .text $elf $imem
    Assert-LastExitCode "IMEM generation $caseName"
    & $script:ObjcopyExe -O verilog --verilog-data-width=4 --reverse-bytes=4 --change-addresses -0x20000000 -j .rodata -j .sdata2.cnv_polarity0 -j .sdata2.cnv_polarity1 -j .data $elf $dmem
    Assert-LastExitCode "DMEM generation $caseName"
    Normalize-VerilogWordAddresses $imem
    Normalize-VerilogWordAddresses $dmem

    $memoryGate = @()
    $imageFirst = ((Get-Content -LiteralPath $imem | Where-Object { $_ -notmatch '^@' -and $_.Trim() } | Select-Object -First 1) -split '\s+')[0].ToUpperInvariant()
    $elfLine = @($objdumpOutput | Where-Object { $_ -match '^\s*0:\s+([0-9a-fA-F]{8})\s+' } | Select-Object -First 1)
    if ($elfLine.Count -ne 1) { throw "ELF first instruction not found for $caseName" }
    $null = $elfLine[0] -match '^\s*0:\s+([0-9a-fA-F]{8})\s+'
    $elfFirst = $Matches[1].ToUpperInvariant()
    if ($imageFirst -ne $elfFirst -or $imageFirst -ne '20010117') {
        throw "IMEM byte-order gate failed for ${caseName}: ELF=$elfFirst image=$imageFirst"
    }
    $memoryGate += "IMEM_GATE PASS elf_first=$elfFirst image_first=$imageFirst"
    $firstMarker = Get-Content -LiteralPath $dmem | Where-Object { $_ -match '^@' } | Select-Object -First 1
    if ($firstMarker -ne '@00000400') { throw "DMEM marker gate failed for ${caseName}: $firstMarker" }
    $memoryGate += "DMEM_ADDRESS_GATE PASS first_marker=$firstMarker byte_address=0x00001000 word_index=0x00000400"

    $headerText = Get-Content -LiteralPath $caseHeader -Raw
    $inputBytes = Get-HeaderArray $headerText 'cnv_input_q7_hwc'
    [uint32]$inputWord = 0
    for ($byte = 0; $byte -lt 4; $byte++) {
        $inputWord = $inputWord -bor (([uint32]($inputBytes[$byte] -band 0xff)) -shl (8 * $byte))
    }
    $threshold0 = Get-HeaderArray $headerText 'cnv_threshold0'
    [uint32]$thresholdWord = ([uint32]($threshold0[0] -band 0xffff)) -bor (([uint32]($threshold0[1] -band 0xffff)) -shl 16)
    $checksums = Get-HeaderArray $headerText 'cnv_expected_layer_checksums'
    $dmemImage = Read-VerilogWordImage $dmem
    $memoryGate += Assert-DmemWord $dmemImage (Get-SymbolAddress $nmOutput 'cnv_input_q7_hwc') $inputWord 'cnv_input_q7_hwc'
    $memoryGate += Assert-DmemWord $dmemImage (Get-SymbolAddress $nmOutput 'cnv_threshold0') $thresholdWord 'cnv_threshold0'
    $memoryGate += Assert-DmemWord $dmemImage (Get-SymbolAddress $nmOutput 'cnv_expected_layer_checksums') ([uint32]$checksums[0]) 'cnv_expected_layer_checksums'
    $fullGateScript = Join-Path $ScriptDir 'check_cnv_dmem_image.py'
    $fullGateOutput = @(& $PythonExe $fullGateScript --header $caseHeader --nm $nmFile --dmem $dmem 2>&1)
    $fullGateExit = $LASTEXITCODE
    $memoryGate += $fullGateOutput
    if ($fullGateExit -ne 0) { throw "Full DMEM image gate failed for $caseName" }
    $memoryGate | Set-Content -LiteralPath (Join-Path $MemoryGateDir "$caseName.log") -Encoding utf8

    return [pscustomobject]@{ Imem = $imem; Dmem = $dmem; Elf = $elf }
}

function Invoke-XSimCase([int]$SampleId, [string]$Phase, [string]$Snapshot) {
    $caseName = 'case_{0:D2}' -f $SampleId
    $caseDir = Join-Path $VectorsDir $caseName
    $metadata = Get-Content -LiteralPath (Join-Path $caseDir 'metadata.json') -Raw | ConvertFrom-Json
    Write-Host "  [$Phase] build + XSim sample=$SampleId dataset=$($metadata.dataset_index) label=$($metadata.ground_truth_label) expected=$($metadata.expected_prediction)"
    $firmware = Build-FirmwareCase $SampleId
    Copy-MemoryFile $firmware.Imem 'imem.hex'
    Copy-MemoryFile $firmware.Dmem 'dmem.hex'
    Copy-MemoryFile (Join-Path $caseDir 'expected_scores.hex') 'scores.hex'
    Copy-MemoryFile (Join-Path $caseDir 'expected_checksums.hex') 'checksums.hex'

    $localLog = "${Phase}_${caseName}_xsim.log"
    $optionsFile = "${Phase}_${caseName}.options"
    @(
        '-tclbatch run_all.tcl',
        '-onfinish quit',
        "-log $localLog",
        '-testplusarg "IMEM=mem/imem.hex"',
        '-testplusarg "DMEM=mem/dmem.hex"',
        '-testplusarg "WEIGHT=mem/weight.hex"',
        '-testplusarg "ACT0=mem/activation0.hex"',
        '-testplusarg "ACT1=mem/activation1.hex"',
        '-testplusarg "SCORES=mem/scores.hex"',
        '-testplusarg "CHECKSUMS=mem/checksums.hex"',
        ('-testplusarg "EXPECTED_PREDICTION={0}"' -f $metadata.expected_prediction),
        ('-testplusarg "SAMPLE_ID={0}"' -f $metadata.sample_id),
        ('-testplusarg "DATASET_INDEX={0}"' -f $metadata.dataset_index),
        ('-testplusarg "GROUND_TRUTH_LABEL={0}"' -f $metadata.ground_truth_label)
    ) | Set-Content -LiteralPath (Join-Path $WorkDir $optionsFile) -Encoding ascii

    & $script:XSimExe $Snapshot -f $optionsFile | Out-Host
    $simExit = $LASTEXITCODE
    $localLogPath = Join-Path $WorkDir $localLog
    $destinationLog = Join-Path $CaseLogsDir $localLog
    if (-not (Test-Path -LiteralPath $localLogPath)) { throw "XSim log missing: $localLogPath" }
    Copy-Item -LiteralPath $localLogPath -Destination $destinationLog -Force
    $resultLines = @(Get-Content -LiteralPath $localLogPath | Where-Object { $_ -match '^RESULT ' })
    if ($resultLines.Count -ne 1) { throw "$caseName emitted $($resultLines.Count) RESULT lines; see $destinationLog" }
    $row = Convert-ResultLineToRow $resultLines[0]
    if ($simExit -ne 0 -or $row.result -ne 'PASS') {
        throw "XSim $Phase $caseName failed; see $destinationLog"
    }
    return $row
}

function Get-CachedPassingRow([int]$SampleId, [string]$Phase) {
    $caseName = 'case_{0:D2}' -f $SampleId
    $path = Join-Path $CaseLogsDir "${Phase}_${caseName}_xsim.log"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $resultLines = @(Get-Content -LiteralPath $path | Where-Object { $_ -match '^RESULT ' })
    if ($resultLines.Count -ne 1) { return $null }
    $row = Convert-ResultLineToRow $resultLines[0]
    if ($row.result -ne 'PASS') { return $null }
    Write-Host "  [$Phase] reusing PASS log sample=$SampleId"
    return $row
}

function Run-Gate([string]$Name, [int[]]$SampleIds, [string]$Snapshot) {
    Write-Host "[$Name] sample IDs: $($SampleIds -join ', ')"
    $gateRows = @()
    foreach ($sampleId in $SampleIds) {
        $gateRows += Invoke-XSimCase $sampleId $Name $Snapshot
    }
    Write-Host "[$Name] PASS newly_run=$($gateRows.Count)"
    return $gateRows
}

foreach ($path in @($PythonExe, $RiscvBin, $VivadoBin, $HardwareDir, $SoftwareDir)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required path is missing: $path" }
}

$script:GccExe = Join-Path $RiscvBin 'riscv32-unknown-elf-gcc.exe'
$script:ObjcopyExe = Join-Path $RiscvBin 'riscv32-unknown-elf-objcopy.exe'
$script:ObjdumpExe = Join-Path $RiscvBin 'riscv32-unknown-elf-objdump.exe'
$script:NmExe = Join-Path $RiscvBin 'riscv32-unknown-elf-nm.exe'
$script:SizeExe = Join-Path $RiscvBin 'riscv32-unknown-elf-size.exe'
$XvlogExe = Join-Path $VivadoBin 'xvlog.bat'
$XelabExe = Join-Path $VivadoBin 'xelab.bat'
$script:XSimExe = Join-Path $VivadoBin 'xsim.bat'
foreach ($tool in @($script:GccExe, $script:ObjcopyExe, $script:ObjdumpExe, $script:NmExe, $script:SizeExe, $XvlogExe, $XelabExe, $script:XSimExe)) {
    if (-not (Test-Path -LiteralPath $tool)) { throw "Required executable is missing: $tool" }
}

New-Item -ItemType Directory -Force -Path $VectorsDir, $ResultsDir, $LogsDir, $CaseLogsDir, $CompileLogsDir, $MemoryGateDir, $WorkDir, $MemDir, $FirmwareRoot | Out-Null

$generator = Join-Path $ScriptDir 'generate_finn_cnv_multiinput_vectors.py'
if ($RegenerateVectors -or -not (Test-Path -LiteralPath (Join-Path $VectorsDir 'case_09\metadata.json'))) {
    Write-Host '[1/7] Generating dependency-light FINN CNV Golden vectors'
    $generatorOutput = & $PythonExe $generator 2>&1
    $generatorExit = $LASTEXITCODE
    $generatorOutput | Set-Content -LiteralPath (Join-Path $LogsDir 'golden_generator.log') -Encoding utf8
    $generatorOutput | ForEach-Object { Write-Host $_ }
    if ($generatorExit -ne 0) { throw "Golden generation failed with exit code $generatorExit" }
    if (@($generatorOutput | Where-Object { $_ -match '^CNV_GOLDEN_GATE .*result=PASS$' }).Count -ne 1) {
        throw 'FINN CNV Golden Gate did not pass'
    }
} else {
    Write-Host '[1/7] Reusing existing Golden vectors (case_00 through case_09)'
    $goldenLog = Join-Path $LogsDir 'golden_generator.log'
    if (-not (Test-Path -LiteralPath $goldenLog) -or
        (Get-Content -LiteralPath $goldenLog -Raw) -notmatch '(?m)^CNV_GOLDEN_GATE .*result=PASS\r?$') {
        throw 'Existing Golden Gate PASS evidence is missing'
    }
}

Write-Host '[2/7] Staging fixed Wide-BDOT128 memory images'
Copy-MemoryFile (Join-Path $SoftwareDir 'generated\weight_128.hex') 'weight.hex'
Copy-MemoryFile (Join-Path $SoftwareDir 'generated\activation0.hex') 'activation0.hex'
Copy-MemoryFile (Join-Path $SoftwareDir 'generated\activation1.hex') 'activation1.hex'

Write-Host '[3/7] Compiling RTL and testbenches with xvlog 2019.1'
$rtlDir = Join-Path $HardwareDir 'rtl'
$multiTb = Join-Path $ModelDir 'testbench\rv32i_cnv_bdot_multi_tb.v'
$singleTb = Join-Path $ModelDir 'testbench\rv32i_cnv_bdot_tb.v'
$rtlSources = @(
    (Join-Path $rtlDir 'basic_modules.v'),
    (Join-Path $rtlDir 'xnor_popcount32.v'),
    (Join-Path $rtlDir 'bdot_cpu_control.v'),
    (Join-Path $rtlDir 'wide_xnor_popcount.v'),
    (Join-Path $rtlDir 'wide_bram_32xwide_model.v'),
    (Join-Path $rtlDir 'wide_bdot_accel.v'),
    (Join-Path $rtlDir 'rv32i_cpu.v'),
    $multiTb,
    $singleTb
)
foreach ($source in $rtlSources) {
    if (-not (Test-Path -LiteralPath $source)) { throw "RTL source is missing: $source" }
}
@('run all', 'quit') | Set-Content -LiteralPath (Join-Path $WorkDir 'run_all.tcl') -Encoding ascii

Push-Location $WorkDir
try {
    & $XvlogExe @rtlSources -log 'xvlog.log' | Out-Host
    Assert-LastExitCode 'xvlog compile'
    Copy-Item -LiteralPath (Join-Path $WorkDir 'xvlog.log') -Destination (Join-Path $CompileLogsDir 'xvlog.log') -Force

    Write-Host '[4/7] Elaborating Multiple-Input and untouched single-input snapshots'
    $multiSnapshot = 'finn_cnv_multi'
    $singleSnapshot = 'finn_cnv_single'
    & $XelabExe -debug off -top rv32i_cnv_bdot_multi_tb -snapshot $multiSnapshot -log 'xelab_multi.log' | Out-Host
    Assert-LastExitCode 'xelab Multiple-Input'
    Copy-Item -LiteralPath (Join-Path $WorkDir 'xelab_multi.log') -Destination (Join-Path $CompileLogsDir 'xelab_multi.log') -Force
    & $XelabExe -debug off -top rv32i_cnv_bdot_tb -snapshot $singleSnapshot -log 'xelab_single.log' | Out-Host
    Assert-LastExitCode 'xelab single-input'
    Copy-Item -LiteralPath (Join-Path $WorkDir 'xelab_single.log') -Destination (Join-Path $CompileLogsDir 'xelab_single.log') -Force

    Write-Host '[5/7] Running staged XSim 2019.1 gates'
    $rows = @()
    $cached = Get-CachedPassingRow 0 'gate1'
    if ($null -eq $cached) { $rows += Run-Gate 'gate1' @(0) $multiSnapshot }
    else { $rows += $cached }
    if ($Through -eq 'Gate1') { Write-Host 'GATE1_COMPLETE'; return }
    $cached = Get-CachedPassingRow 1 'gate2_new_input'
    if ($null -eq $cached) { $rows += Run-Gate 'gate2_new_input' @(1) $multiSnapshot }
    else { $rows += $cached }
    if ($Through -eq 'Gate2') { Write-Host 'GATE2_COMPLETE cumulative=2'; return }
    foreach ($sampleId in @(2, 3, 4, 5, 6, 7, 8, 9)) {
        $cached = Get-CachedPassingRow $sampleId 'final_remaining'
        if ($null -eq $cached) { $rows += Run-Gate 'final_remaining' @($sampleId) $multiSnapshot }
        else { $rows += $cached }
    }
    $rows = @($rows | Sort-Object sample_id)

    Write-Host '[6/7] Running untouched FINN CNV single-input testbench'
    $case0Build = Join-Path $FirmwareRoot 'case_00'
    Copy-MemoryFile (Join-Path $case0Build 'imem.hex') 'imem.hex'
    Copy-MemoryFile (Join-Path $case0Build 'dmem.hex') 'dmem.hex'
    $legacyLog = 'legacy_single_input_xsim.log'
    @(
        '-tclbatch run_all.tcl',
        '-onfinish quit',
        "-log $legacyLog",
        '-testplusarg "IMEM=mem/imem.hex"',
        '-testplusarg "DMEM=mem/dmem.hex"',
        '-testplusarg "WEIGHT=mem/weight.hex"',
        '-testplusarg "ACT0=mem/activation0.hex"',
        '-testplusarg "ACT1=mem/activation1.hex"'
    ) | Set-Content -LiteralPath (Join-Path $WorkDir 'legacy_single_input.options') -Encoding ascii
    & $script:XSimExe $singleSnapshot -f 'legacy_single_input.options' | Out-Host
    $legacyExit = $LASTEXITCODE
    $legacyPath = Join-Path $WorkDir $legacyLog
    $legacyDestination = Join-Path $LogsDir 'legacy_single_input.log'
    Copy-Item -LiteralPath $legacyPath -Destination $legacyDestination -Force
    $legacyText = Get-Content -LiteralPath $legacyPath -Raw
    if ($legacyExit -ne 0 -or $legacyText -notmatch '(?m)^TB PASS: FINN CNV BDOT128$') {
        throw "Untouched single-input XSim regression failed; see $legacyDestination"
    }
    $legacyResult = [regex]::Match($legacyText, 'CNV BDOT result cycles=(\d+) bdot=(\d+) blocks=(\d+) bcfg=(\d+) errors=(\d+)')
    $legacyStatus = [regex]::Match($legacyText, 'CNV BDOT status=(\d+) prediction=(\d+) expected=(\d+) correct=(\d+) checks=(\d+)')
    $legacyScores = [regex]::Match($legacyText, 'CNV BDOT scores=([^\r\n]+)')
    if (-not $legacyResult.Success -or -not $legacyStatus.Success -or -not $legacyScores.Success) {
        throw 'Could not parse untouched single-input result'
    }

    Write-Host '[7/7] Writing CSV and Markdown summaries'
    $csvPath = Join-Path $ResultsDir 'finn_cnv_multiinput_results.csv'
    $mdPath = Join-Path $ResultsDir 'finn_cnv_multiinput_results.md'
    $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8
    $total = $rows.Count
    $predictionPass = @($rows | Where-Object prediction_match -eq 'PASS').Count
    $scorePass = @($rows | Where-Object score_match -eq 'PASS').Count
    $checksumPass = @($rows | Where-Object checksum_match -eq 'PASS').Count
    $cycleStats = $rows | Measure-Object cycles -Minimum -Maximum -Average
    $cycleMin = [int]$cycleStats.Minimum
    $cycleMax = [int]$cycleStats.Maximum
    $cycleAverage = [Math]::Round($cycleStats.Average, 2)
    $cycleRange = $cycleMax - $cycleMin
    $bdotUnique = @($rows.bdot_count | Sort-Object -Unique)
    $blockUnique = @($rows.block_count | Sort-Object -Unique)
    $classCoverage = @($rows.ground_truth_label | Sort-Object -Unique)
    $overallPass = ($total -eq 10) -and ($predictionPass -eq $total) -and
        ($scorePass -eq $total) -and ($checksumPass -eq $total) -and
        (@($rows | Where-Object result -ne 'PASS').Count -eq 0)

    $md = @(
        '# FINN CNV Wide-BDOT128 10-Input XSim 2019.1 Validation',
        '',
        '## 검증 환경',
        '',
        '- Vivado Simulator 2019.1의 xvlog, xelab, xsim을 사용함.',
        '- 공식 CIFAR-10 test split의 실제 input을 사용함.',
        '- Exported Weight/Threshold/Polarity 기반 독립 Golden을 생성함.',
        '- 기존 Wide-BDOT128 RTL architecture를 수정하지 않음.',
        '',
        '## Golden Gate',
        '',
        '- 공식 FINN class-3 sample과 CIFAR-10 test index 0의 raw pixel이 exact match함.',
        '- HWC int8 Q1.7 packed input이 기존 header와 exact match함.',
        '- Prediction, class score 10개, intermediate checksum 10개가 기존 reference와 exact match함.',
        '',
        '## 결과',
        '',
        "- 전체 sample은 ${total}개이며 Overall 결과는 $(if ($overallPass) { 'PASS' } else { 'FAIL' })임.",
        "- Ground-truth class coverage는 $($classCoverage -join ', ')임.",
        "- Prediction exact match는 $predictionPass/${total}임.",
        "- Class score exact match는 $scorePass/${total}임.",
        "- Intermediate checksum 10개 전체 exact match는 $checksumPass/${total}임.",
        "- Cycle은 minimum $cycleMin, maximum $cycleMax, average $cycleAverage, range ${cycleRange}임.",
        "- BDOT count unique value는 $($bdotUnique -join ', ')임.",
        "- Block count unique value는 $($blockUnique -join ', ')임.",
        '',
        '| Sample | Dataset Index | Label | Expected | Actual | Score | Checksum | Cycles | BDOT | Blocks | Result |',
        '|---:|---:|---:|---:|---:|:---:|:---:|---:|---:|---:|:---:|'
    )
    foreach ($row in $rows) {
        $md += "| $($row.sample_id) | $($row.dataset_index) | $($row.ground_truth_label) | $($row.expected_prediction) | $($row.actual_prediction) | $($row.score_match) | $($row.checksum_match) | $($row.cycles) | $($row.bdot_count) | $($row.block_count) | $($row.result) |"
    }
    $md += @(
        '',
        '## 기존 Single-Input Regression',
        '',
        "- Prediction은 $($legacyStatus.Groups[2].Value), expected는 $($legacyStatus.Groups[3].Value)이며 PASS함.",
        "- Scores는 [$($legacyScores.Groups[1].Value)]이며 기존 기준과 exact match함.",
        "- Intermediate checksum 검증 값은 $($legacyStatus.Groups[5].Value)이며 PASS함.",
        "- Cycles는 $($legacyResult.Groups[1].Value), BDOT은 $($legacyResult.Groups[2].Value), Blocks는 $($legacyResult.Groups[3].Value)임.",
        '',
        '## 범위',
        '',
        '- 본 결과는 RTL XSim validation 범위임.',
        '- FPGA Multiple-Input execution은 수행하지 않음.'
    )
    $md | Set-Content -LiteralPath $mdPath -Encoding utf8
    if (-not $overallPass) { throw '10-input summary contains a failure' }
    Write-Host "FINAL PASS samples=$total classes=$($classCoverage.Count) prediction=$predictionPass score=$scorePass checksum=$checksumPass cycle_min=$cycleMin cycle_max=$cycleMax cycle_average=$cycleAverage cycle_range=$cycleRange bdot=$($bdotUnique -join ',') blocks=$($blockUnique -join ',')"
    Write-Host "CSV: $csvPath"
    Write-Host "Markdown: $mdPath"
    Write-Host "Logs: $LogsDir"
} finally {
    Pop-Location
}
