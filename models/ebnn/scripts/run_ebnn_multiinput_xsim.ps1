[CmdletBinding()]
param(
    [ValidateSet('Single', 'Full')]
    [string]$Mode = 'Single',
    [switch]$RegenerateVectors,
    [string]$PythonExe = 'C:\Users\AERO\AppData\Local\Programs\Python\Python312\python.exe',
    [string]$VivadoBin = 'C:\Xilinx\Vivado\2019.1\bin'
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModelDir = (Resolve-Path -LiteralPath (Join-Path $ScriptDir '..')).Path
$RepositoryRoot = (Resolve-Path -LiteralPath (Join-Path $ModelDir '..\..')).Path
$HardwareDir = Join-Path $RepositoryRoot 'hardware\wide_bdot128'
$SoftwareDir = Join-Path $ModelDir 'software\ebnn'
$CommonDir = Join-Path $ModelDir 'baseline\common'
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
    if ($LASTEXITCODE -ne 0) { throw "$Step failed with exit code $LASTEXITCODE" }
}

function Convert-ToWslPath([string]$Path) {
    $absolute = [System.IO.Path]::GetFullPath($Path)
    if ($absolute -notmatch '^([A-Za-z]):\\(.*)$') { throw "Unsupported Windows path: $Path" }
    $drive = $Matches[1].ToLowerInvariant()
    $tail = $Matches[2].Replace('\', '/')
    return "/mnt/$drive/$tail"
}

function Invoke-WslTool([string]$Tool, [string[]]$Arguments, [string]$Step) {
    $output = @(& wsl.exe --exec $Tool @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $output | ForEach-Object { Write-Host $_ }
        throw "$Step failed with exit code $exitCode"
    }
    return $output
}

function Normalize-VerilogWordAddresses([string]$Path) {
    $normalized = foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^@([0-9a-fA-F]+)(.*)$') {
            $byteAddress = [Convert]::ToUInt64($Matches[1], 16)
            if (($byteAddress % 4) -ne 0) { throw "Unaligned Verilog byte address: $line" }
            '@{0:X8}{1}' -f [uint64]($byteAddress / 4), $Matches[2]
        } else {
            $line
        }
    }
    $normalized | Set-Content -LiteralPath $Path -Encoding ascii
}

function Get-ResultFields([string]$Line) {
    $fields = @{}
    foreach ($token in ($Line -split '\s+')) {
        if ($token -match '^([^=]+)=(.*)$') { $fields[$Matches[1]] = $Matches[2] }
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
        activation_match = $fields.activation_match
        cycles = [int]$fields.cycles
        bdot_count = [int]$fields.bdot_count
        block_count = [int]$fields.block_count
        status = [int]$fields.status
        result = $fields.result
    }
}

function Copy-MemoryFile([string]$Source, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "Memory file is missing: $Source" }
    Copy-Item -LiteralPath $Source -Destination (Join-Path $MemDir $Name) -Force
}

function Get-LoadableDmemSections([string[]]$SectionOutput) {
    $sections = @()
    for ($index = 0; $index -lt ($SectionOutput.Count - 1); $index++) {
        $line = [string]$SectionOutput[$index]
        if ($line -match '^\s*\d+\s+(\S+)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+') {
            $name = $Matches[1]
            $size = [Convert]::ToUInt64($Matches[2], 16)
            $vma = [Convert]::ToUInt64($Matches[3], 16)
            $flags = [string]$SectionOutput[$index + 1]
            if ($size -gt 0 -and $vma -ge 0x20000000 -and $vma -lt 0x20010000 -and
                $flags -match 'CONTENTS' -and $flags -match 'LOAD') {
                $sections += $name
            }
        }
    }
    return @($sections | Sort-Object -Unique)
}

function Build-FirmwareCase([int]$SampleId) {
    $caseName = 'case_{0:D2}' -f $SampleId
    $buildDir = Join-Path $FirmwareRoot $caseName
    New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

    $elf = Join-Path $buildDir 'ebnn_bdot128.elf'
    $map = Join-Path $buildDir 'ebnn_bdot128.map'
    $asm = Join-Path $buildDir 'ebnn_bdot128.asm'
    $nmFile = Join-Path $buildDir 'ebnn_bdot128.nm'
    $sectionFile = Join-Path $buildDir 'ebnn_bdot128.sections'
    $imem = Join-Path $buildDir 'imem.hex'
    $dmem = Join-Path $buildDir 'dmem.hex'

    $gccArgs = @(
        '-march=rv32i', '-mabi=ilp32', '-O2', '-g0',
        '-ffunction-sections', '-fdata-sections', '-fno-builtin', '-nostdlib',
        "-DEBNN_SAMPLE_ID=$SampleId",
        '-I', (Convert-ToWslPath (Join-Path $SoftwareDir 'validation_include')),
        '-I', (Convert-ToWslPath $SoftwareDir),
        '-I', (Convert-ToWslPath $CommonDir),
        '-Wl,--gc-sections', "-Wl,-Map,$(Convert-ToWslPath $map)",
        '-T', (Convert-ToWslPath (Join-Path $SoftwareDir 'memory_bdot.ld')),
        (Convert-ToWslPath (Join-Path $ModelDir 'baseline\RISC-V\crt0.S')),
        (Convert-ToWslPath (Join-Path $SoftwareDir 'main_ebnn_bdot_multi.c')),
        '-lgcc', '-o', (Convert-ToWslPath $elf)
    )
    $buildOutput = Invoke-WslTool 'riscv64-unknown-elf-gcc' $gccArgs "RISC-V firmware build $caseName"
    $buildOutput | Set-Content -LiteralPath (Join-Path $buildDir 'firmware_build.log') -Encoding utf8

    $sizeOutput = Invoke-WslTool 'riscv64-unknown-elf-size' @((Convert-ToWslPath $elf)) "RISC-V size $caseName"
    $sizeOutput | Set-Content -LiteralPath (Join-Path $buildDir 'firmware_size.log') -Encoding ascii
    $asmOutput = Invoke-WslTool 'riscv64-unknown-elf-objdump' @('-d', (Convert-ToWslPath $elf)) "RISC-V objdump $caseName"
    $asmOutput | Set-Content -LiteralPath $asm -Encoding ascii
    $compressed = @($asmOutput | Where-Object { $_ -match '^\s*[0-9a-fA-F]+:\s+[0-9a-fA-F]{4}\s+' })
    if ($compressed.Count -ne 0) { throw "RV32I ISA gate failed: $($compressed[0])" }
    $nmOutput = Invoke-WslTool 'riscv64-unknown-elf-nm' @('-n', (Convert-ToWslPath $elf)) "RISC-V nm $caseName"
    $nmOutput | Set-Content -LiteralPath $nmFile -Encoding ascii
    $sectionOutput = Invoke-WslTool 'riscv64-unknown-elf-objdump' @('-h', (Convert-ToWslPath $elf)) "RISC-V section list $caseName"
    $sectionOutput | Set-Content -LiteralPath $sectionFile -Encoding ascii
    $dmemSections = Get-LoadableDmemSections $sectionOutput
    if ($dmemSections.Count -eq 0) { throw "No loadable DMEM sections found for $caseName" }

    $null = Invoke-WslTool 'riscv64-unknown-elf-objcopy' @(
        '-O', 'verilog', '--verilog-data-width=4', '--reverse-bytes=4', '-j', '.text',
        (Convert-ToWslPath $elf), (Convert-ToWslPath $imem)
    ) "IMEM generation $caseName"
    $dmemArgs = @('-O', 'verilog', '--verilog-data-width=4', '--reverse-bytes=4', '--change-addresses', '-0x20000000')
    foreach ($section in $dmemSections) { $dmemArgs += @('-j', $section) }
    $dmemArgs += @((Convert-ToWslPath $elf), (Convert-ToWslPath $dmem))
    $null = Invoke-WslTool 'riscv64-unknown-elf-objcopy' $dmemArgs "DMEM generation $caseName"
    Normalize-VerilogWordAddresses $imem
    Normalize-VerilogWordAddresses $dmem

    $firstWord = ((Get-Content -LiteralPath $imem | Where-Object { $_ -notmatch '^@' -and $_.Trim() } | Select-Object -First 1) -split '\s+')[0].ToUpperInvariant()
    $firstInstruction = @($asmOutput | Where-Object { $_ -match '^\s*0:\s+([0-9a-fA-F]{8})\s+' } | Select-Object -First 1)
    if ($firstInstruction.Count -ne 1) { throw "First instruction not found for $caseName" }
    $null = $firstInstruction[0] -match '^\s*0:\s+([0-9a-fA-F]{8})\s+'
    $elfFirst = $Matches[1].ToUpperInvariant()
    if ($firstWord -ne $elfFirst -or $firstWord -ne '20010117') {
        throw "IMEM byte-order gate failed for ${caseName}: ELF=$elfFirst image=$firstWord"
    }

    $memoryGate = @(
        "ISA_GATE PASS march=rv32i compressed_instructions=0",
        "IMEM_GATE PASS elf_first=$elfFirst image_first=$firstWord",
        "DMEM_SECTION_GATE PASS sections=$($dmemSections -join ',')"
    )
    $checker = Join-Path $ScriptDir 'check_ebnn_dmem_image.py'
    $checkerOutput = @(& $PythonExe $checker `
        --data-header (Join-Path $CommonDir 'binary_mnist_data.h') `
        --model-header (Join-Path $CommonDir 'binary_mnist.h') `
        --nm $nmFile --dmem $dmem `
        --weight-image (Join-Path $SoftwareDir 'generated\weight_128.hex') 2>&1)
    $checkerExit = $LASTEXITCODE
    $memoryGate += $checkerOutput
    $memoryGate | Set-Content -LiteralPath (Join-Path $MemoryGateDir "$caseName.log") -Encoding utf8
    if ($checkerExit -ne 0) { throw "Full DMEM gate failed for $caseName" }

    return [pscustomobject]@{ Imem = $imem; Dmem = $dmem; Elf = $elf }
}

function Get-CachedPassingRow([int]$SampleId) {
    $caseName = 'case_{0:D2}' -f $SampleId
    $path = Join-Path $CaseLogsDir "${caseName}_xsim.log"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $resultLines = @(Get-Content -LiteralPath $path | Where-Object { $_ -match '^RESULT ' })
    if ($resultLines.Count -ne 1) { return $null }
    $row = Convert-ResultLineToRow $resultLines[0]
    if ($row.result -ne 'PASS') { return $null }
    Write-Host "  [resume] reusing PASS sample=$SampleId"
    return $row
}

function Invoke-XSimCase([int]$SampleId, [string]$Snapshot) {
    $caseName = 'case_{0:D2}' -f $SampleId
    $caseDir = Join-Path $VectorsDir $caseName
    $metadata = Get-Content -LiteralPath (Join-Path $caseDir 'metadata.json') -Raw -Encoding utf8 | ConvertFrom-Json
    Write-Host "  [XSim] sample=$SampleId label=$($metadata.ground_truth_label) expected=$($metadata.expected_prediction)"
    $firmware = Build-FirmwareCase $SampleId
    Copy-MemoryFile $firmware.Imem 'imem.hex'
    Copy-MemoryFile $firmware.Dmem 'dmem.hex'
    Copy-MemoryFile (Join-Path $caseDir 'expected_scores.hex') 'scores.hex'
    Copy-MemoryFile (Join-Path $caseDir 'expected_activation.hex') 'expected_activation.hex'
    Copy-MemoryFile (Join-Path $caseDir 'expected_checksum.hex') 'expected_checksum.hex'

    $localLog = "${caseName}_xsim.log"
    $optionsFile = "${caseName}.options"
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
        '-testplusarg "ACTIVATION=mem/expected_activation.hex"',
        '-testplusarg "CHECKSUM=mem/expected_checksum.hex"',
        ('-testplusarg "SAMPLE_ID={0}"' -f $metadata.sample_id),
        ('-testplusarg "GROUND_TRUTH_LABEL={0}"' -f $metadata.ground_truth_label),
        ('-testplusarg "EXPECTED_PREDICTION={0}"' -f $metadata.expected_prediction)
    ) | Set-Content -LiteralPath (Join-Path $WorkDir $optionsFile) -Encoding ascii

    & $script:XSimExe $Snapshot -f $optionsFile | Out-Host
    $simExit = $LASTEXITCODE
    $localLogPath = Join-Path $WorkDir $localLog
    $destinationLog = Join-Path $CaseLogsDir $localLog
    if (-not (Test-Path -LiteralPath $localLogPath)) { throw "XSim log missing: $localLogPath" }
    Copy-Item -LiteralPath $localLogPath -Destination $destinationLog -Force
    $resultLines = @(Get-Content -LiteralPath $localLogPath | Where-Object { $_ -match '^RESULT ' })
    if ($resultLines.Count -ne 1) { throw "$caseName emitted $($resultLines.Count) RESULT lines" }
    $row = Convert-ResultLineToRow $resultLines[0]
    if ($simExit -ne 0 -or $row.result -ne 'PASS') { throw "XSim $caseName failed; see $destinationLog" }
    return $row
}

function Write-FullSummary([object[]]$Rows) {
    $rows = @($Rows | Sort-Object sample_id)
    $csvPath = Join-Path $ResultsDir 'ebnn_multiinput_results.csv'
    $mdPath = Join-Path $ResultsDir 'ebnn_multiinput_results.md'
    $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8
    $total = $rows.Count
    $predictionPass = @($rows | Where-Object prediction_match -eq 'PASS').Count
    $scorePass = @($rows | Where-Object score_match -eq 'PASS').Count
    $checksumPass = @($rows | Where-Object checksum_match -eq 'PASS').Count
    $activationPass = @($rows | Where-Object activation_match -eq 'PASS').Count
    $cycleStats = $rows | Measure-Object cycles -Minimum -Maximum -Average
    $cycleMin = [int]$cycleStats.Minimum
    $cycleMax = [int]$cycleStats.Maximum
    $cycleAverage = [Math]::Round($cycleStats.Average, 2)
    $cycleRange = $cycleMax - $cycleMin
    $bdotUnique = @($rows.bdot_count | Sort-Object -Unique)
    $blockUnique = @($rows.block_count | Sort-Object -Unique)
    $overall = $total -eq 20 -and $predictionPass -eq 20 -and $scorePass -eq 20 -and
               $checksumPass -eq 20 -and $activationPass -eq 20 -and
               @($rows | Where-Object result -ne 'PASS').Count -eq 0

    if (-not $overall) { throw '20-input summary contains a failure' }
    & $PythonExe (Join-Path $ScriptDir 'write_ebnn_results_markdown.py') full --csv $csvPath --output $mdPath
    Assert-LastExitCode 'UTF-8 full result Markdown generation'
    Write-Host "FINAL PASS samples=$total prediction=$predictionPass score=$scorePass checksum=$checksumPass activation=$activationPass cycle_min=$cycleMin cycle_max=$cycleMax cycle_average=$cycleAverage cycle_range=$cycleRange bdot=$($bdotUnique -join ',') blocks=$($blockUnique -join ',')"
    Write-Host "CSV: $csvPath"
    Write-Host "Markdown: $mdPath"
}

foreach ($path in @($PythonExe, $VivadoBin, $HardwareDir, $SoftwareDir, $CommonDir)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required path is missing: $path" }
}
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { throw 'WSL is not available' }
$toolCheck = Invoke-WslTool 'riscv64-unknown-elf-gcc' @('-march=rv32i', '-mabi=ilp32', '-print-libgcc-file-name') 'WSL RV32I toolchain gate'
if (($toolCheck -join "`n") -notmatch '/rv32i/ilp32/libgcc\.a$') { throw "WSL RV32I multilib was not selected: $toolCheck" }

$XvlogExe = Join-Path $VivadoBin 'xvlog.bat'
$XelabExe = Join-Path $VivadoBin 'xelab.bat'
$script:XSimExe = Join-Path $VivadoBin 'xsim.bat'
foreach ($tool in @($XvlogExe, $XelabExe, $script:XSimExe)) {
    if (-not (Test-Path -LiteralPath $tool)) { throw "XSim tool is missing: $tool" }
}

New-Item -ItemType Directory -Force -Path $VectorsDir, $ResultsDir, $LogsDir, $CaseLogsDir, $CompileLogsDir, $MemoryGateDir, $WorkDir, $MemDir, $FirmwareRoot | Out-Null
$generator = Join-Path $ScriptDir 'generate_ebnn_multiinput_vectors.py'
$goldenLog = Join-Path $LogsDir 'golden_generator.log'
if ($RegenerateVectors -or -not (Test-Path -LiteralPath (Join-Path $VectorsDir 'case_19\metadata.json'))) {
    $generatorOutput = @(& $PythonExe $generator 2>&1)
    $generatorExit = $LASTEXITCODE
    $generatorOutput | Set-Content -LiteralPath $goldenLog -Encoding utf8
    $generatorOutput | ForEach-Object { Write-Host $_ }
    if ($generatorExit -ne 0 -or @($generatorOutput | Where-Object { $_ -match '^EBNN_GOLDEN_GATE .*result=PASS$' }).Count -ne 1) {
        throw 'eBNN Golden Gate failed'
    }
} else {
    Write-Host '[Golden] Reusing existing 20-input vectors'
    if (-not (Test-Path -LiteralPath $goldenLog)) {
        & $PythonExe $generator 2>&1 | Set-Content -LiteralPath $goldenLog -Encoding utf8
        Assert-LastExitCode 'eBNN Golden Gate evidence'
    }
}

Copy-MemoryFile (Join-Path $SoftwareDir 'generated\weight_128.hex') 'weight.hex'
Copy-MemoryFile (Join-Path $SoftwareDir 'generated\activation0.hex') 'activation0.hex'
Copy-MemoryFile (Join-Path $SoftwareDir 'generated\activation1.hex') 'activation1.hex'

$rtlDir = Join-Path $HardwareDir 'rtl'
$testbench = Join-Path $ModelDir 'testbench\rv32i_ebnn_bdot_multi_tb.v'
$rtlSources = @(
    (Join-Path $rtlDir 'basic_modules.v'),
    (Join-Path $rtlDir 'xnor_popcount32.v'),
    (Join-Path $rtlDir 'bdot_cpu_control.v'),
    (Join-Path $rtlDir 'wide_xnor_popcount.v'),
    (Join-Path $rtlDir 'wide_bram_32xwide_model.v'),
    (Join-Path $rtlDir 'wide_bdot_accel.v'),
    (Join-Path $rtlDir 'rv32i_cpu.v'),
    $testbench
)
@('run all', 'quit') | Set-Content -LiteralPath (Join-Path $WorkDir 'run_all.tcl') -Encoding ascii

Push-Location $WorkDir
try {
    & $XvlogExe @rtlSources -log 'xvlog.log' | Out-Host
    Assert-LastExitCode 'xvlog compile'
    Copy-Item -LiteralPath (Join-Path $WorkDir 'xvlog.log') -Destination (Join-Path $CompileLogsDir 'xvlog.log') -Force
    $snapshot = 'ebnn_multi'
    & $XelabExe -debug off -top rv32i_ebnn_bdot_multi_tb -snapshot $snapshot -log 'xelab.log' | Out-Host
    Assert-LastExitCode 'xelab eBNN Multiple-Input'
    Copy-Item -LiteralPath (Join-Path $WorkDir 'xelab.log') -Destination (Join-Path $CompileLogsDir 'xelab.log') -Force

    $sampleIds = if ($Mode -eq 'Single') { @(0) } else { @(0..19) }
    $rows = @()
    foreach ($sampleId in $sampleIds) {
        $cached = Get-CachedPassingRow $sampleId
        if ($null -eq $cached) { $rows += Invoke-XSimCase $sampleId $snapshot }
        else { $rows += $cached }
    }

    if ($Mode -eq 'Single') {
        $row = $rows[0]
        & $PythonExe (Join-Path $ScriptDir 'write_ebnn_results_markdown.py') single `
            --log (Join-Path $CaseLogsDir 'case_00_xsim.log') `
            --output (Join-Path $ResultsDir 'ebnn_single_input_gate.md')
        Assert-LastExitCode 'UTF-8 single-input Markdown generation'
        Write-Host "SINGLE PASS sample=0 prediction=$($row.actual_prediction) cycles=$($row.cycles) bdot=$($row.bdot_count) blocks=$($row.block_count)"
    } else {
        Write-FullSummary $rows
    }
} finally {
    Pop-Location
}
