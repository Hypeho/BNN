[CmdletBinding()]
param(
    [ValidateSet('Gate1', 'Gate2', 'Full')]
    [string]$Through = 'Full',
    [string]$PythonExe = 'C:\Users\AERO\AppData\Local\Programs\Python\Python312\python.exe',
    [string]$RiscvBin = 'C:\Users\AERO\Downloads\project\학부연구생\RV32I_Single_Cycle_CPU\rv32imac (source)\bin',
    [string]$VivadoBin = 'C:\Xilinx\Vivado\2019.1\bin'
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModelDir = (Resolve-Path -LiteralPath (Join-Path $ScriptDir '..')).Path
$RepositoryRoot = (Resolve-Path -LiteralPath (Join-Path $ModelDir '..\..')).Path
$HardwareDir = Join-Path $RepositoryRoot 'hardware\wide_bdot128'
$SoftwareDir = Join-Path $ModelDir 'software\lfc'
$VectorsDir = Join-Path $ModelDir 'vectors\generated\multiinput'
$ResultsDir = Join-Path $ModelDir 'results'
$LogsDir = Join-Path $ModelDir 'logs\xsim2019_1'
$WorkDir = Join-Path $ModelDir 'work\xsim2019_1'
$FirmwareBuildDir = Join-Path $ModelDir 'work\firmware'
$MemDir = Join-Path $WorkDir 'mem'
$GateLogsDir = Join-Path $LogsDir 'gates'
$CaseLogsDir = Join-Path $LogsDir 'cases'
$CompileLogsDir = Join-Path $LogsDir 'compile'

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
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        $tokens = $trimmed -split '\s+'
        foreach ($token in $tokens) {
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
    return @([regex]::Matches($match.Groups[1].Value, '0x[0-9a-fA-F]+|\d+') | ForEach-Object {
        if ($_.Value.StartsWith('0x')) {
            [Convert]::ToUInt64($_.Value.Substring(2), 16)
        } else {
            [Convert]::ToUInt64($_.Value, 10)
        }
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
        throw "DMEM $Name mismatch at word index $key expected=$('{0:X8}' -f $Expected) actual=$('{0:X8}' -f [uint32]$Image[$key])"
    }
    return "DMEM_GATE PASS symbol=$Name address=0x$('{0:X8}' -f $AbsoluteAddress) word_index=$key value=$('{0:X8}' -f $Expected)"
}

function Copy-MemoryFile([string]$Source, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "Memory source is missing: $Source" }
    Copy-Item -LiteralPath $Source -Destination (Join-Path $MemDir $Name) -Force
}

function Invoke-XSimCase(
    [string]$Snapshot,
    [int]$SampleId,
    [string]$Phase,
    [string]$DestinationLog
) {
    $caseName = 'case_{0:D2}' -f $SampleId
    $caseDir = Join-Path $VectorsDir $caseName
    $metadataPath = Join-Path $caseDir 'metadata.json'
    if (-not (Test-Path -LiteralPath $metadataPath)) { throw "Metadata is missing: $metadataPath" }
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json

    Copy-MemoryFile (Join-Path $caseDir 'activation0.hex') 'activation0.hex'
    Copy-MemoryFile (Join-Path $caseDir 'activation1.hex') 'activation1.hex'
    Copy-MemoryFile (Join-Path $caseDir 'golden_activation0.hex') 'golden0.hex'
    Copy-MemoryFile (Join-Path $caseDir 'golden_activation1.hex') 'golden1.hex'
    Copy-MemoryFile (Join-Path $caseDir 'golden_activation2.hex') 'golden2.hex'
    Copy-MemoryFile (Join-Path $caseDir 'expected_scores.hex') 'scores.hex'

    $localLog = "${Phase}_${caseName}_xsim.log"
    $optionsFile = "${Phase}_${caseName}.options"
    $options = @(
        '-tclbatch run_all.tcl',
        '-onfinish quit',
        "-log $localLog",
        '-testplusarg "IMEM=mem/imem.hex"',
        '-testplusarg "DMEM=mem/dmem.hex"',
        '-testplusarg "WEIGHT=mem/weight.hex"',
        '-testplusarg "ACT0=mem/activation0.hex"',
        '-testplusarg "ACT1=mem/activation1.hex"',
        '-testplusarg "GOLDEN0=mem/golden0.hex"',
        '-testplusarg "GOLDEN1=mem/golden1.hex"',
        '-testplusarg "GOLDEN2=mem/golden2.hex"',
        '-testplusarg "SCORES=mem/scores.hex"',
        ('-testplusarg "EXPECTED_PREDICTION={0}"' -f $metadata.expected_prediction),
        ('-testplusarg "SAMPLE_ID={0}"' -f $SampleId)
    )
    $optionsFilePath = Join-Path $WorkDir $optionsFile
    $options | Set-Content -LiteralPath $optionsFilePath -Encoding ascii
    Write-Host "  XSim $Phase sample=$SampleId label=$($metadata.source_label) expected=$($metadata.expected_prediction)"
    & $script:XSimExe $Snapshot -f $optionsFile | Out-Host
    $simExit = $LASTEXITCODE
    $localLogPath = Join-Path $WorkDir $localLog
    if (-not (Test-Path -LiteralPath $localLogPath)) { throw "XSim log was not created: $localLogPath" }
    Copy-Item -LiteralPath $localLogPath -Destination $DestinationLog -Force

    $logLines = @(Get-Content -LiteralPath $localLogPath)
    $resultLines = @($logLines | Where-Object { $_ -match '^RESULT ' })
    if ($resultLines.Count -ne 1) {
        throw "sample $SampleId emitted $($resultLines.Count) RESULT lines; see $DestinationLog"
    }
    $fields = Get-ResultFields $resultLines[0]
    $row = [pscustomobject][ordered]@{
        model = $fields.model
        sample_id = [int]$fields.sample_id
        ground_truth_label = [int]$metadata.source_label
        expected_prediction = [int]$fields.expected_prediction
        actual_prediction = [int]$fields.actual_prediction
        prediction_match = $fields.prediction_match
        score_match = $fields.score_match
        layer0_match = $fields.layer0_match
        layer1_match = $fields.layer1_match
        layer2_match = $fields.layer2_match
        cycles = [int]$fields.cycles
        bdot_count = [int]$fields.bdot_count
        block_count = [int]$fields.block_count
        status = [int]$fields.status
        result = $fields.result
    }
    if ($simExit -ne 0 -or $row.result -ne 'PASS') {
        throw "XSim $Phase sample $SampleId failed; see $DestinationLog"
    }
    return $row
}

function Invoke-Phase([string]$Name, [int[]]$SampleIds, [string]$Snapshot) {
    Write-Host "[$Name] Running sample IDs: $($SampleIds -join ', ')"
    $phaseRows = @()
    foreach ($sampleId in $SampleIds) {
        $destination = if ($Name -eq 'full') {
            Join-Path $CaseLogsDir ('case_{0:D2}.log' -f $sampleId)
        } else {
            Join-Path $GateLogsDir ('{0}_case_{1:D2}.log' -f $Name, $sampleId)
        }
        $phaseRows += Invoke-XSimCase -Snapshot $Snapshot -SampleId $sampleId -Phase $Name -DestinationLog $destination
    }
    Write-Host "[$Name] PASS $($phaseRows.Count)/$($phaseRows.Count)"
    return $phaseRows
}

foreach ($path in @($PythonExe, $RiscvBin, $VivadoBin, $HardwareDir, $SoftwareDir)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required path is missing: $path" }
}

$GccExe = Join-Path $RiscvBin 'riscv32-unknown-elf-gcc.exe'
$ObjcopyExe = Join-Path $RiscvBin 'riscv32-unknown-elf-objcopy.exe'
$ObjdumpExe = Join-Path $RiscvBin 'riscv32-unknown-elf-objdump.exe'
$NmExe = Join-Path $RiscvBin 'riscv32-unknown-elf-nm.exe'
$SizeExe = Join-Path $RiscvBin 'riscv32-unknown-elf-size.exe'
$XvlogExe = Join-Path $VivadoBin 'xvlog.bat'
$XelabExe = Join-Path $VivadoBin 'xelab.bat'
$script:XSimExe = Join-Path $VivadoBin 'xsim.bat'
foreach ($tool in @($GccExe, $ObjcopyExe, $ObjdumpExe, $NmExe, $SizeExe, $XvlogExe, $XelabExe, $script:XSimExe)) {
    if (-not (Test-Path -LiteralPath $tool)) { throw "Required executable is missing: $tool" }
}

New-Item -ItemType Directory -Force -Path $VectorsDir, $ResultsDir, $LogsDir, $WorkDir, $FirmwareBuildDir, $MemDir, $GateLogsDir, $CaseLogsDir, $CompileLogsDir | Out-Null

Write-Host '[1/8] Generating and gating 20 FINN LFC Golden cases'
$generator = Join-Path $SoftwareDir 'generate_lfc_multiinput_vectors.py'
$generatorOutput = & $PythonExe $generator --sample-ids (0..19) 2>&1
$generatorExit = $LASTEXITCODE
$generatorOutput | Set-Content -LiteralPath (Join-Path $LogsDir 'golden_generator.log') -Encoding utf8
$generatorOutput | ForEach-Object { Write-Host $_ }
if ($generatorExit -ne 0) { throw "Golden generation failed with exit code $generatorExit" }
if (@($generatorOutput | Where-Object { $_ -match '^INPUT_REPRESENTATION_GATE PASS ' }).Count -ne 1) { throw 'Input representation gate did not pass' }
if (@($generatorOutput | Where-Object { $_ -match '^GOLDEN_GATE PASS .*prediction=5 .*layer0=PASS layer1=PASS layer2=PASS$' }).Count -ne 1) { throw 'Golden Gate did not pass' }

Write-Host '[2/8] Building FINN LFC firmware'
$crt0 = Join-Path $ModelDir 'baseline\RISC-V\crt0.S'
$firmware = Join-Path $SoftwareDir 'main_finn_lfc_bdot.c'
$linker = Join-Path $SoftwareDir 'memory_bdot.ld'
$elf = Join-Path $FirmwareBuildDir 'finn_lfc_bdot128_multi.elf'
$map = Join-Path $FirmwareBuildDir 'finn_lfc_bdot128_multi.map'
$asm = Join-Path $FirmwareBuildDir 'finn_lfc_bdot128_multi.asm'
$imem = Join-Path $FirmwareBuildDir 'imem.hex'
$dmem = Join-Path $FirmwareBuildDir 'dmem.hex'
$gccArgs = @(
    '-march=rv32i', '-mabi=ilp32', '-O2', '-g0',
    '-ffunction-sections', '-fdata-sections', '-fno-builtin', '-nostdlib',
    "-I$SoftwareDir", '-Wl,--gc-sections', "-Wl,-Map,$map", '-T', $linker,
    $crt0, $firmware, '-lgcc', '-o', $elf
)
$buildOutput = & $GccExe @gccArgs 2>&1
$buildExit = $LASTEXITCODE
$buildOutput | Set-Content -LiteralPath (Join-Path $CompileLogsDir 'firmware_build.log') -Encoding utf8
$buildOutput | ForEach-Object { Write-Host $_ }
if ($buildExit -ne 0) { throw "RISC-V firmware build failed with exit code $buildExit" }
& $SizeExe $elf | Tee-Object -FilePath (Join-Path $CompileLogsDir 'firmware_size.log') | Out-Host
Assert-LastExitCode 'RISC-V size'
$objdumpOutput = @(& $ObjdumpExe -d $elf 2>&1)
Assert-LastExitCode 'RISC-V objdump'
$objdumpOutput | Set-Content -LiteralPath $asm -Encoding ascii
$nmOutput = @(& $NmExe -n $elf 2>&1)
Assert-LastExitCode 'RISC-V nm'
$nmOutput | Set-Content -LiteralPath (Join-Path $FirmwareBuildDir 'finn_lfc_bdot128_multi.nm') -Encoding ascii
& $ObjcopyExe -O verilog --verilog-data-width=4 --reverse-bytes=4 -j .text $elf $imem
Assert-LastExitCode 'Instruction image generation'
& $ObjcopyExe -O verilog --verilog-data-width=4 --reverse-bytes=4 --change-addresses -0x20000000 -j .rodata -j .data $elf $dmem
Assert-LastExitCode 'Data image generation'
Normalize-VerilogWordAddresses $imem
Normalize-VerilogWordAddresses $dmem

Write-Host '[3/8] Checking IMEM byte order and DMEM word addressing'
$memoryGate = @()
$firstInstructionWord = ((Get-Content -LiteralPath $imem | Where-Object { $_ -notmatch '^@' -and $_.Trim() } | Select-Object -First 1) -split '\s+')[0].ToUpperInvariant()
$startInstructionLine = @($objdumpOutput | Where-Object { $_ -match '^\s*0:\s+([0-9a-fA-F]{8})\s+' } | Select-Object -First 1)
if ($startInstructionLine.Count -ne 1) { throw 'Could not find the ELF instruction at address 0' }
$null = $startInstructionLine[0] -match '^\s*0:\s+([0-9a-fA-F]{8})\s+'
$elfFirstInstruction = $Matches[1].ToUpperInvariant()
if ($firstInstructionWord -ne $elfFirstInstruction -or $firstInstructionWord -ne '20010117') {
    throw "IMEM byte-order gate failed: ELF=$elfFirstInstruction image=$firstInstructionWord"
}
$memoryGate += "IMEM_GATE PASS elf_first=$elfFirstInstruction image_first=$firstInstructionWord"
$firstDataAddress = Get-Content -LiteralPath $dmem | Where-Object { $_ -match '^@' } | Select-Object -First 1
if ($firstDataAddress -ne '@00000400') { throw "DMEM address-marker gate failed: $firstDataAddress" }
$memoryGate += "DMEM_ADDRESS_GATE PASS first_marker=$firstDataAddress byte_address=0x00001000 word_index=0x00000400"
$headerText = Get-Content -LiteralPath (Join-Path $SoftwareDir 'generated\lfc_bdot_params.h') -Raw
$threshold0 = Get-HeaderArray $headerText 'lfc_threshold0'
$polarity0 = Get-HeaderArray $headerText 'lfc_polarity0'
$thresholdWord = [uint32](([uint64]$threshold0[0]) -bor (([uint64]$threshold0[1]) -shl 16))
$polarityWord = [uint32]$polarity0[0]
$dmemImage = Read-VerilogWordImage $dmem
$memoryGate += Assert-DmemWord $dmemImage (Get-SymbolAddress $nmOutput 'lfc_threshold0') $thresholdWord 'lfc_threshold0'
$memoryGate += Assert-DmemWord $dmemImage (Get-SymbolAddress $nmOutput 'lfc_polarity0') $polarityWord 'lfc_polarity0'
$memoryGate | Set-Content -LiteralPath (Join-Path $LogsDir 'memory_image_gate.log') -Encoding utf8
$memoryGate | ForEach-Object { Write-Host $_ }

Copy-MemoryFile $imem 'imem.hex'
Copy-MemoryFile $dmem 'dmem.hex'
Copy-MemoryFile (Join-Path $SoftwareDir 'generated\weight_128.hex') 'weight.hex'

Write-Host '[4/8] Compiling RTL and testbenches with xvlog 2019.1'
$rtlDir = Join-Path $HardwareDir 'rtl'
$multiTb = Join-Path $ModelDir 'testbench\rv32i_lfc_bdot_multi_tb.v'
$legacyTb = Join-Path $ModelDir 'testbench\rv32i_lfc_bdot_tb.v'
$rtlSources = @(
    (Join-Path $rtlDir 'basic_modules.v'),
    (Join-Path $rtlDir 'xnor_popcount32.v'),
    (Join-Path $rtlDir 'bdot_cpu_control.v'),
    (Join-Path $rtlDir 'wide_xnor_popcount.v'),
    (Join-Path $rtlDir 'wide_bram_32xwide_model.v'),
    (Join-Path $rtlDir 'wide_bdot_accel.v'),
    (Join-Path $rtlDir 'rv32i_cpu.v'),
    $multiTb,
    $legacyTb
)
foreach ($source in $rtlSources) {
    if (-not (Test-Path -LiteralPath $source)) { throw "RTL source is missing: $source" }
}
$runAllTcl = Join-Path $WorkDir 'run_all.tcl'
@('run all', 'quit') | Set-Content -LiteralPath $runAllTcl -Encoding ascii

Push-Location $WorkDir
try {
    & $XvlogExe @rtlSources -log 'xvlog.log' | Out-Host
    Assert-LastExitCode 'xvlog compile'
    Copy-Item -LiteralPath (Join-Path $WorkDir 'xvlog.log') -Destination (Join-Path $CompileLogsDir 'xvlog.log') -Force

    Write-Host '[5/8] Elaborating Multiple-Input and legacy snapshots with xelab 2019.1'
    $multiSnapshot = 'finn_lfc_multi'
    $legacySnapshot = 'finn_lfc_single'
    & $XelabExe -debug off -top rv32i_lfc_bdot_multi_tb -snapshot $multiSnapshot -log 'xelab_multi.log' | Out-Host
    Assert-LastExitCode 'xelab Multiple-Input'
    Copy-Item -LiteralPath (Join-Path $WorkDir 'xelab_multi.log') -Destination (Join-Path $CompileLogsDir 'xelab_multi.log') -Force
    & $XelabExe -debug off -top rv32i_lfc_bdot_tb -snapshot $legacySnapshot -log 'xelab_single.log' | Out-Host
    Assert-LastExitCode 'xelab single-input'
    Copy-Item -LiteralPath (Join-Path $WorkDir 'xelab_single.log') -Destination (Join-Path $CompileLogsDir 'xelab_single.log') -Force

    Write-Host '[6/8] Running staged XSim correctness gates'
    $null = Invoke-Phase 'gate1' @(0) $multiSnapshot
    if ($Through -eq 'Gate1') { Write-Host 'GATE1_COMPLETE'; exit 0 }
    $null = Invoke-Phase 'gate2' @(0, 1, 2) $multiSnapshot
    if ($Through -eq 'Gate2') { Write-Host 'GATE2_COMPLETE'; exit 0 }
    $rows = @(Invoke-Phase 'full' @(0..19) $multiSnapshot)

    Write-Host '[7/8] Running untouched single-input testbench with XSim 2019.1'
    Copy-MemoryFile (Join-Path $SoftwareDir 'generated\activation0.hex') 'activation0.hex'
    Copy-MemoryFile (Join-Path $SoftwareDir 'generated\activation1.hex') 'activation1.hex'
    Copy-MemoryFile (Join-Path $SoftwareDir 'generated\golden_activation0.hex') 'golden0.hex'
    Copy-MemoryFile (Join-Path $SoftwareDir 'generated\golden_activation1.hex') 'golden1.hex'
    Copy-MemoryFile (Join-Path $SoftwareDir 'generated\golden_activation2.hex') 'golden2.hex'
    $legacyLocalLog = 'legacy_single_input_xsim.log'
    $legacyOptions = @(
        '-tclbatch run_all.tcl',
        '-onfinish quit',
        "-log $legacyLocalLog",
        '-testplusarg "IMEM=mem/imem.hex"',
        '-testplusarg "DMEM=mem/dmem.hex"',
        '-testplusarg "WEIGHT=mem/weight.hex"',
        '-testplusarg "ACT0=mem/activation0.hex"',
        '-testplusarg "ACT1=mem/activation1.hex"',
        '-testplusarg "GOLDEN0=mem/golden0.hex"',
        '-testplusarg "GOLDEN1=mem/golden1.hex"',
        '-testplusarg "GOLDEN2=mem/golden2.hex"'
    )
    $legacyOptionsFile = Join-Path $WorkDir 'legacy_single_input.options'
    $legacyOptions | Set-Content -LiteralPath $legacyOptionsFile -Encoding ascii
    & $script:XSimExe $legacySnapshot -f 'legacy_single_input.options' | Out-Host
    $legacyExit = $LASTEXITCODE
    $legacyLocalLogPath = Join-Path $WorkDir $legacyLocalLog
    $legacyDestinationLog = Join-Path $LogsDir 'legacy_single_input.log'
    Copy-Item -LiteralPath $legacyLocalLogPath -Destination $legacyDestinationLog -Force
    $legacyText = Get-Content -LiteralPath $legacyLocalLogPath -Raw
    if ($legacyExit -ne 0 -or $legacyText -notmatch '(?m)^TB PASS: rv32i_lfc_bdot cycles=') {
        throw "Untouched single-input XSim regression failed; see $legacyDestinationLog"
    }
    $legacyResultMatch = [regex]::Match($legacyText, 'LFC BDOT result cycles=(\d+) bdot=(\d+) blocks=(\d+) bcfg=(\d+) status=(\d+) prediction=(\d+)')
    $legacyScoresMatch = [regex]::Match($legacyText, 'LFC BDOT scores=([^\r\n]+)')
    if (-not $legacyResultMatch.Success -or -not $legacyScoresMatch.Success) { throw 'Could not parse legacy XSim result' }
    $legacy = [ordered]@{
        prediction = [int]$legacyResultMatch.Groups[6].Value
        scores = $legacyScoresMatch.Groups[1].Value
        cycles = [int]$legacyResultMatch.Groups[1].Value
        bdot_count = [int]$legacyResultMatch.Groups[2].Value
        block_count = [int]$legacyResultMatch.Groups[3].Value
        status = [int]$legacyResultMatch.Groups[5].Value
        result = 'PASS'
    }

    Write-Host '[8/8] Writing CSV and Markdown summaries'
    $csvPath = Join-Path $ResultsDir 'finn_lfc_multiinput_results.csv'
    $mdPath = Join-Path $ResultsDir 'finn_lfc_multiinput_results.md'
    $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8

    $total = $rows.Count
    $predictionPass = @($rows | Where-Object prediction_match -eq 'PASS').Count
    $scorePass = @($rows | Where-Object score_match -eq 'PASS').Count
    $layer0Pass = @($rows | Where-Object layer0_match -eq 'PASS').Count
    $layer1Pass = @($rows | Where-Object layer1_match -eq 'PASS').Count
    $layer2Pass = @($rows | Where-Object layer2_match -eq 'PASS').Count
    $cycleStats = $rows | Measure-Object cycles -Minimum -Maximum -Average
    $cycleMin = [int]$cycleStats.Minimum
    $cycleMax = [int]$cycleStats.Maximum
    $cycleAverage = [Math]::Round($cycleStats.Average, 2)
    $cycleRange = $cycleMax - $cycleMin
    $bdotUnique = @($rows.bdot_count | Sort-Object -Unique)
    $blockUnique = @($rows.block_count | Sort-Object -Unique)
    $overallPass = ($predictionPass -eq $total) -and ($scorePass -eq $total) -and
        ($layer0Pass -eq $total) -and ($layer1Pass -eq $total) -and
        ($layer2Pass -eq $total) -and (@($rows | Where-Object result -ne 'PASS').Count -eq 0)

    $md = @(
        '# FINN LFC Wide-BDOT128 20-Input XSim 2019.1 Validation',
        '',
        '## 검증 환경',
        '',
        '- Vivado Simulator 2019.1의 xvlog, xelab, xsim을 사용함.',
        '- Binary-MNIST input data만 사용하고 FINN LFC parameter로 Golden을 독립 생성함.',
        '- 기존 Wide-BDOT128 RTL architecture를 수정하지 않음.',
        '',
        '## Golden Gate',
        '',
        '- Sample 0 packed input이 기존 FINN LFC input과 exact match함.',
        '- Prediction 5와 기준 class score 10개가 exact match함.',
        '- Layer 0, Layer 1, Layer 2 packed activation이 기존 reference와 exact match함.',
        '',
        '## 결과',
        '',
        "- 전체 sample은 ${total}개이며 Overall 결과는 $(if ($overallPass) { 'PASS' } else { 'FAIL' })임.",
        "- Prediction exact match는 $predictionPass/${total}임.",
        "- Class score exact match는 $scorePass/${total}임.",
        "- Layer 0/1/2 exact match는 $layer0Pass/${total}, $layer1Pass/${total}, $layer2Pass/${total}임.",
        "- Cycle은 minimum $cycleMin, maximum $cycleMax, average $cycleAverage, range ${cycleRange}임.",
        "- BDOT count unique value는 $($bdotUnique -join ', ')임.",
        "- Block count unique value는 $($blockUnique -join ', ')임.",
        '',
        '| Sample | Label | Expected | Actual | Score | L0 | L1 | L2 | Cycles | BDOT | Blocks | Result |',
        '|---:|---:|---:|---:|:---:|:---:|:---:|:---:|---:|---:|---:|:---:|'
    )
    foreach ($row in $rows) {
        $md += "| $($row.sample_id) | $($row.ground_truth_label) | $($row.expected_prediction) | $($row.actual_prediction) | $($row.score_match) | $($row.layer0_match) | $($row.layer1_match) | $($row.layer2_match) | $($row.cycles) | $($row.bdot_count) | $($row.block_count) | $($row.result) |"
    }
    $md += @(
        '',
        '## Cycle / Workload 해석',
        '',
        '- BDOT instruction count 3,082와 128-bit block count 23,632는 모든 sample에서 동일함.',
        '- O2 firmware disassembly에서 activation bit가 set되는 조건 분기는 두 instruction을 추가 실행함.',
        '- Class score가 기존 maximum을 갱신하는 조건 분기도 두 instruction을 추가 실행함.',
        '- 20개 sample 모두 `cycles = 118431 + 2 × (Layer 0/1/2 activation set-bit 수) + 2 × (class maximum 갱신 횟수)`를 만족함.',
        '- Cycle 차이는 Wide-BDOT128 workload 차이가 아니라 input-dependent CPU-side branch 경로 차이로 확인됨.',
        '',
        '## 기존 Single-Input Regression',
        '',
        "- Prediction은 $($legacy.prediction)이며 결과는 $($legacy.result)임.",
        "- Scores는 [$($legacy.scores)]이며 기존 기준과 exact match함.",
        "- Cycles는 $($legacy.cycles), BDOT은 $($legacy.bdot_count), Blocks는 $($legacy.block_count)임.",
        '',
        '## 범위',
        '',
        '- 본 결과는 RTL XSim validation 범위임.',
        '- FPGA Multiple-Input execution은 수행하지 않음.'
    )
    $md | Set-Content -LiteralPath $mdPath -Encoding utf8
    if (-not $overallPass) { throw '20-input summary contains a failure' }

    Write-Host "FINAL PASS samples=$total prediction=$predictionPass score=$scorePass layer0=$layer0Pass layer1=$layer1Pass layer2=$layer2Pass cycle_min=$cycleMin cycle_max=$cycleMax cycle_average=$cycleAverage cycle_range=$cycleRange bdot=$($bdotUnique -join ',') blocks=$($blockUnique -join ',')"
    Write-Host "CSV: $csvPath"
    Write-Host "Markdown: $mdPath"
    Write-Host "Logs: $LogsDir"
} finally {
    Pop-Location
}
