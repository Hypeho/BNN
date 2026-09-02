[CmdletBinding()]
param()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModelDir = (Resolve-Path -LiteralPath (Join-Path $ScriptDir '..')).Path
$CaseLogsDir = Join-Path $ModelDir 'logs\xsim2019_1\cases'
$WorkDir = Join-Path $ModelDir 'work\xsim2019_1'
$CsvPath = Join-Path $ModelDir 'results\ebnn_multiinput_results.csv'

$processes = @(Get-Process -Name xsimk -ErrorAction SilentlyContinue)
if ($processes.Count -eq 0) {
    Write-Host 'XSIMK running: NO'
} else {
    Write-Host 'XSIMK running: YES'
    $processes | Select-Object Id, StartTime, CPU, Path | Format-Table -AutoSize
}

$latestOptions = Get-ChildItem -LiteralPath $WorkDir -Filter 'case_*.options' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($null -eq $latestOptions) {
    Write-Host 'Latest case: none'
} else {
    Write-Host "Latest case: $($latestOptions.BaseName)"
}

$passLogs = @()
if (Test-Path -LiteralPath $CaseLogsDir) {
    $passLogs = @(Get-ChildItem -LiteralPath $CaseLogsDir -Filter 'case_*_xsim.log' -File |
        Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '(?m)^RESULT .*result=PASS\r?$' })
}
Write-Host "Completed PASS cases: $($passLogs.Count) / 20"
Write-Host "Final CSV exists: $(if (Test-Path -LiteralPath $CsvPath) { 'YES' } else { 'NO' })"
