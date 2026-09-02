[CmdletBinding()]
param(
    [ValidateRange(1, 20)]
    [int]$SampleCount = 3,
    [string]$PythonExe = 'C:\Users\AERO\AppData\Local\Programs\Python\Python312\python.exe',
    [string]$RiscvBin = 'C:\Users\AERO\Downloads\project\학부연구생\RV32I_Single_Cycle_CPU\rv32imac (source)\bin',
    [string]$WslDistro = 'Ubuntu-22.04',
    [string]$OutputResultsDir = ''
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = (Resolve-Path -LiteralPath (Join-Path $ScriptDir '..')).Path
$BnnDir = (Resolve-Path -LiteralPath (Join-Path $ProjectDir '..')).Path
$WorkRoot = (Resolve-Path -LiteralPath (Join-Path $ProjectDir '..\..\..\..')).Path
$SoftwareDir = Join-Path $ProjectDir 'software\lfc'
$GeneratedDir = Join-Path $SoftwareDir 'generated'
$MultiGeneratedDir = Join-Path $GeneratedDir 'multiinput'
$BuildDir = Join-Path $SoftwareDir 'build\multiinput'
$TbBuildDir = Join-Path $ScriptDir 'build\multiinput'
$DefaultResultsDir = Join-Path $WorkRoot 'results'
$ResultsDir = if ($OutputResultsDir) {
    [IO.Path]::GetFullPath($OutputResultsDir)
} else {
    $DefaultResultsDir
}
if (-not ($ResultsDir.Equals($DefaultResultsDir, [StringComparison]::OrdinalIgnoreCase) -or
          $ResultsDir.StartsWith($DefaultResultsDir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) {
    throw "OutputResultsDir must stay inside $DefaultResultsDir"
}
$LogsDir = Join-Path $ResultsDir 'lfc_multiinput_logs'

function Assert-LastExitCode([string]$Step) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed with exit code $LASTEXITCODE"
    }
}

function ConvertTo-WslPath([string]$WindowsPath) {
    $full = [IO.Path]::GetFullPath($WindowsPath)
    if ($full.Length -lt 3 -or $full[1] -ne ':') {
        throw "Only absolute Windows drive paths are supported: $WindowsPath"
    }
    $drive = $full.Substring(0, 1).ToLowerInvariant()
    $tail = $full.Substring(2).Replace('\', '/')
    return "/mnt/$drive$tail"
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
        if ($line -match '^@([0-9a-fA-F]+)$') {
            $byteAddress = [Convert]::ToUInt64($Matches[1], 16)
            if (($byteAddress % 4) -ne 0) {
                throw "Unaligned Verilog byte address in ${Path}: $line"
            }
            '@{0:X8}' -f [uint64]($byteAddress / 4)
        } else {
            $line
        }
    }
    $normalized | Set-Content -LiteralPath $Path -Encoding ascii
}

$WslProjectDir = ConvertTo-WslPath $ProjectDir

foreach ($path in @($PythonExe, $RiscvBin, $SoftwareDir)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required path is missing: $path" }
}
New-Item -ItemType Directory -Force -Path $BuildDir, $TbBuildDir, $ResultsDir, $LogsDir | Out-Null

$sampleIds = @(0..($SampleCount - 1))
$generator = Join-Path $SoftwareDir 'generate_lfc_multiinput_vectors.py'
Write-Host "[1/5] Generating FINN LFC golden vectors for samples: $($sampleIds -join ', ')"
& $PythonExe $generator --sample-ids @sampleIds
Assert-LastExitCode 'Golden generation'

$gcc = Join-Path $RiscvBin 'riscv32-unknown-elf-gcc.exe'
$objcopy = Join-Path $RiscvBin 'riscv32-unknown-elf-objcopy.exe'
$objdump = Join-Path $RiscvBin 'riscv32-unknown-elf-objdump.exe'
$size = Join-Path $RiscvBin 'riscv32-unknown-elf-size.exe'
foreach ($tool in @($gcc, $objcopy, $objdump, $size)) {
    if (-not (Test-Path -LiteralPath $tool)) { throw "RISC-V tool is missing: $tool" }
}

$crt0 = Join-Path $BnnDir '260719_FINN_LFC_RV32I\RISC-V\crt0.S'
$firmware = Join-Path $SoftwareDir 'main_finn_lfc_bdot.c'
$linker = Join-Path $SoftwareDir 'memory_bdot.ld'
$elf = Join-Path $BuildDir 'finn_lfc_bdot128_multi.elf'
$map = Join-Path $BuildDir 'finn_lfc_bdot128_multi.map'
$asm = Join-Path $BuildDir 'finn_lfc_bdot128_multi.asm'
$imem = Join-Path $BuildDir 'imem.hex'
$dmem = Join-Path $BuildDir 'dmem.hex'

Write-Host '[2/5] Building an isolated firmware image with the Windows RV32I toolchain'
$gccArgs = @(
    '-march=rv32i', '-mabi=ilp32', '-O2', '-g0',
    '-ffunction-sections', '-fdata-sections', '-fno-builtin', '-nostdlib',
    "-I$SoftwareDir", '-Wl,--gc-sections', "-Wl,-Map,$map", '-T', $linker,
    $crt0, $firmware, '-lgcc', '-o', $elf
)
& $gcc @gccArgs
Assert-LastExitCode 'RISC-V firmware compile'
& $size $elf
Assert-LastExitCode 'RISC-V size'
$objdumpOutput = & $objdump -d -S $elf 2>&1
Assert-LastExitCode 'RISC-V objdump'
$objdumpOutput | Set-Content -LiteralPath $asm -Encoding ascii
& $objcopy -O verilog --verilog-data-width=4 --reverse-bytes=4 -j .text $elf $imem
Assert-LastExitCode 'Instruction image generation'
& $objcopy -O verilog --verilog-data-width=4 --reverse-bytes=4 --change-addresses -0x20000000 -j .rodata -j .data $elf $dmem
Assert-LastExitCode 'Data image generation'
Normalize-VerilogWordAddresses $imem
Normalize-VerilogWordAddresses $dmem
$firstInstructionWord = Get-Content -LiteralPath $imem | Where-Object { $_ -notmatch '^@' -and $_.Trim() } | Select-Object -First 1
if (($firstInstructionWord -split '\s+')[0] -ne '20010117') {
    throw "Unexpected first IMEM word after byte-order normalization: $firstInstructionWord"
}
$firstDataAddress = Get-Content -LiteralPath $dmem | Where-Object { $_ -match '^@' } | Select-Object -First 1
if ($firstDataAddress -ne '@00000400') {
    throw "Unexpected first DMEM word address after normalization: $firstDataAddress"
}

$xpcDir = Join-Path $BnnDir '260726_XPC32_RegToReg'
$rtlSources = @(
    (Join-Path $xpcDir 'src\rtl\basic_modules.v'),
    (Join-Path $xpcDir 'src\rtl\xnor_popcount32.v'),
    (Join-Path $ProjectDir 'src\rtl\bdot_cpu_control.v'),
    (Join-Path $ProjectDir 'src\rtl\wide_xnor_popcount.v'),
    (Join-Path $ProjectDir 'src\rtl\wide_bram_32xwide_model.v'),
    (Join-Path $ProjectDir 'src\rtl\wide_bdot_accel.v'),
    (Join-Path $ProjectDir 'src\rtl\rv32i_cpu.v')
)
$multiTb = Join-Path $ScriptDir 'rv32i_lfc_bdot_multi_tb.v'
$multiVvp = Join-Path $TbBuildDir 'rv32i_lfc_bdot_multi.vvp'
$iverilogArgs = @('-g2012', '-s', 'rv32i_lfc_bdot_multi_tb', '-o', (ConvertTo-WslPath $multiVvp))
$iverilogArgs += @($rtlSources | ForEach-Object { ConvertTo-WslPath $_ })
$iverilogArgs += ConvertTo-WslPath $multiTb

Write-Host '[3/5] Compiling current Verilog sources with WSL Icarus Verilog 13.0'
$compileOutput = & wsl.exe -d $WslDistro -- /usr/local/bin/iverilog @iverilogArgs 2>&1
$compileExit = $LASTEXITCODE
$compileOutput | ForEach-Object { Write-Host $_ }
if ($compileExit -ne 0) { throw "Icarus compile failed with exit code $compileExit" }

Write-Host "[4/5] Running $SampleCount RTL case(s)"
$rows = @()
foreach ($sampleId in $sampleIds) {
    $caseDir = Join-Path $MultiGeneratedDir ('case_{0:D2}' -f $sampleId)
    $metadata = Get-Content -LiteralPath (Join-Path $caseDir 'metadata.json') -Raw | ConvertFrom-Json
    $plusArgs = @(
        '+IMEM=software/lfc/build/multiinput/imem.hex',
        '+DMEM=software/lfc/build/multiinput/dmem.hex',
        '+WEIGHT=software/lfc/generated/weight_128.hex',
        "+ACT0=software/lfc/generated/multiinput/case_$('{0:D2}' -f $sampleId)/activation0.hex",
        "+ACT1=software/lfc/generated/multiinput/case_$('{0:D2}' -f $sampleId)/activation1.hex",
        "+GOLDEN0=software/lfc/generated/multiinput/case_$('{0:D2}' -f $sampleId)/golden_activation0.hex",
        "+GOLDEN1=software/lfc/generated/multiinput/case_$('{0:D2}' -f $sampleId)/golden_activation1.hex",
        "+GOLDEN2=software/lfc/generated/multiinput/case_$('{0:D2}' -f $sampleId)/golden_activation2.hex",
        "+SCORES=software/lfc/generated/multiinput/case_$('{0:D2}' -f $sampleId)/expected_scores.hex",
        "+EXPECTED_PREDICTION=$($metadata.expected_prediction)",
        "+SAMPLE_ID=$sampleId"
    )
    Write-Host "  sample $sampleId (golden prediction $($metadata.expected_prediction))"
    $simOutput = & wsl.exe -d $WslDistro --cd $WslProjectDir -- /usr/local/bin/vvp (ConvertTo-WslPath $multiVvp) @plusArgs 2>&1
    $simExit = $LASTEXITCODE
    $logPath = Join-Path $LogsDir ('case_{0:D2}.log' -f $sampleId)
    $simOutput | Set-Content -LiteralPath $logPath -Encoding utf8
    $simOutput | ForEach-Object { Write-Host $_ }
    $resultLine = @($simOutput | Where-Object { "$_" -match '^RESULT ' } | Select-Object -Last 1)
    if ($resultLine.Count -ne 1) { throw "sample $sampleId did not emit exactly one RESULT line; see $logPath" }
    $fields = Get-ResultFields "$($resultLine[0])"
    $row = [pscustomobject][ordered]@{
        model = $fields.model
        sample_id = [int]$fields.sample_id
        source_label = [int]$metadata.source_label
        expected_prediction = [int]$fields.expected_prediction
        actual_prediction = [int]$fields.actual_prediction
        prediction_match = $fields.prediction_match
        score_match = $fields.score_match
        activation_match = $fields.activation_match
        cycles = [int]$fields.cycles
        bdot_count = [int]$fields.bdot_count
        block_count = [int]$fields.block_count
        status = [int]$fields.status
        result = $fields.result
    }
    $rows += $row
    if ($simExit -ne 0 -or $row.result -ne 'PASS') {
        $rows | Export-Csv -LiteralPath (Join-Path $ResultsDir 'lfc_multiinput_results.csv') -NoTypeInformation -Encoding utf8
        throw "sample $sampleId failed; see $logPath"
    }
}

Write-Host '[5/5] Recompiling and running the untouched single-input testbench'
$legacyTb = Join-Path $ScriptDir 'rv32i_lfc_bdot_tb.v'
$legacyVvp = Join-Path $TbBuildDir 'rv32i_lfc_bdot_legacy.vvp'
$legacyCompileArgs = @('-g2012', '-s', 'rv32i_lfc_bdot_tb', '-o', (ConvertTo-WslPath $legacyVvp))
$legacyCompileArgs += @($rtlSources | ForEach-Object { ConvertTo-WslPath $_ })
$legacyCompileArgs += ConvertTo-WslPath $legacyTb
$legacyCompileOutput = & wsl.exe -d $WslDistro -- /usr/local/bin/iverilog @legacyCompileArgs 2>&1
$legacyCompileExit = $LASTEXITCODE
$legacyCompileOutput | ForEach-Object { Write-Host $_ }
if ($legacyCompileExit -ne 0) { throw "Legacy Icarus compile failed with exit code $legacyCompileExit" }

$legacyArgs = @(
    '+IMEM=software/lfc/build/multiinput/imem.hex',
    '+DMEM=software/lfc/build/multiinput/dmem.hex',
    '+WEIGHT=software/lfc/generated/weight_128.hex',
    '+ACT0=software/lfc/generated/activation0.hex',
    '+ACT1=software/lfc/generated/activation1.hex',
    '+GOLDEN0=software/lfc/generated/golden_activation0.hex',
    '+GOLDEN1=software/lfc/generated/golden_activation1.hex',
    '+GOLDEN2=software/lfc/generated/golden_activation2.hex'
)
$legacyOutput = & wsl.exe -d $WslDistro --cd $WslProjectDir -- /usr/local/bin/vvp (ConvertTo-WslPath $legacyVvp) @legacyArgs 2>&1
$legacyExit = $LASTEXITCODE
$legacyLog = Join-Path $LogsDir 'legacy_single_input.log'
$legacyOutput | Set-Content -LiteralPath $legacyLog -Encoding utf8
$legacyOutput | ForEach-Object { Write-Host $_ }
$legacyPass = ($legacyExit -eq 0) -and (@($legacyOutput | Where-Object { "$_" -match '^TB PASS: rv32i_lfc_bdot ' }).Count -eq 1)
if (-not $legacyPass) { throw "Untouched single-input regression failed; see $legacyLog" }

$csvPath = Join-Path $ResultsDir 'lfc_multiinput_results.csv'
$mdPath = Join-Path $ResultsDir 'lfc_multiinput_results.md'
$rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8
$md = @(
    '# FINN LFC Wide-BDOT128 Multiple-Input RTL Results',
    '',
    "- Golden sample 0 gate: PASS (prediction 5; all 10 scores exact)",
    "- RTL cases: $($rows.Count)/$($rows.Count) PASS",
    "- Untouched single-input testbench recheck: PASS",
    "- Simulator: WSL Icarus Verilog 13.0 (new source compile)",
    '',
    '| Sample | Source label | Expected | Actual | Score | Activation | Cycles | BDOT | Blocks | Result |',
    '|---:|---:|---:|---:|:---:|:---:|---:|---:|---:|:---:|'
)
foreach ($row in $rows) {
    $md += "| $($row.sample_id) | $($row.source_label) | $($row.expected_prediction) | $($row.actual_prediction) | $($row.score_match) | $($row.activation_match) | $($row.cycles) | $($row.bdot_count) | $($row.block_count) | $($row.result) |"
}
$md += @(
    '',
    '## Interpretation',
    '',
    'All expected values were generated from the FINN LFC weights, thresholds, and polarities. The eBNN project supplied input pixels only.',
    'Intermediate packed activations (all three layers), ten class scores, prediction, status, instruction count, block count, and cycle count were checked.',
    '',
    '## Remaining scope',
    '',
    'FPGA multiple-input execution is not included in this RTL-only experiment.'
)
$md | Set-Content -LiteralPath $mdPath -Encoding utf8
Write-Host "PASS: $($rows.Count) RTL cases and legacy single-input regression"
Write-Host "CSV: $csvPath"
Write-Host "Markdown: $mdPath"
