param(
    [string]$VivadoBin = 'C:\AMDDesignTools\2026.1\Vivado\bin',
    [switch]$IncludePreprocess
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$workspaceRoot = Split-Path -Parent $projectRoot
$simulationRoot = Join-Path $projectRoot 'verification\full_sim'
$reportRoot = Join-Path $projectRoot 'reports'
New-Item -ItemType Directory -Force -Path $simulationRoot, $reportRoot | Out-Null
$summaryPath = Join-Path $reportRoot 'simulation_summary.json'
if (Test-Path -LiteralPath $summaryPath) { Remove-Item -LiteralPath $summaryPath }

# These benches exercise camera detection, real SCCB transactions, capture,
# diagnostic status and VGA. The optional normalizer is parked for phase two.
$benches = @(
    @{ Name = 'tb_ov7670_config'; Marker = 'OV7670_CONFIG_TEST_PASS' },
    @{ Name = 'tb_ov7670_capture'; Marker = 'OV7670_CAPTURE_TEST_PASS' },
    @{ Name = 'tb_ov7670_capture_full'; Marker = 'OV7670_CAPTURE_FULL_TEST_PASS' },
    @{ Name = 'tb_camera_vga'; Marker = 'PASS: camera_vga four full rasters' },
    @{ Name = 'tb_camera_test_top'; Marker = 'CAMERA_TEST_TOP_PASS' }
)
if ($IncludePreprocess) {
    $benches += @{ Name = 'tb_camera_preprocess'; Marker = 'CAMERA_PREPROCESS_PASS' }
}
$rtl = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'rtl') -Filter '*.v' | ForEach-Object FullName)
$rtl += Join-Path $workspaceRoot 'verilog-uart\rtl\uart_tx.v'
$rtl += Join-Path $workspaceRoot 'verilog-uart\rtl\uart_rx.v'
$results = @()
foreach ($bench in $benches) {
    $benchFile = Join-Path $projectRoot ('tb\' + $bench.Name + '.v')
    if (!(Test-Path -LiteralPath $benchFile)) { throw "Missing testbench: $benchFile" }
    $benchRoot = Join-Path $simulationRoot $bench.Name
    New-Item -ItemType Directory -Path $benchRoot -Force | Out-Null
    Push-Location -LiteralPath $benchRoot
    try {
        & (Join-Path $VivadoBin 'xvlog.bat') --sv @rtl $benchFile *> compile.log
        if ($LASTEXITCODE -ne 0) { throw "Compile failed for $($bench.Name); see $benchRoot\compile.log" }
        & (Join-Path $VivadoBin 'xelab.bat') -L unisims_ver --snapshot camera_test_sim ('work.' + $bench.Name) *> elaborate.log
        if ($LASTEXITCODE -ne 0) { throw "Elaboration failed for $($bench.Name); see $benchRoot\elaborate.log" }
        & (Join-Path $VivadoBin 'xsim.bat') camera_test_sim --runall --onfinish quit *> simulation.log
        if ($LASTEXITCODE -ne 0) { throw "Simulation failed for $($bench.Name); see $benchRoot\simulation.log" }
        $passed = Select-String -LiteralPath 'simulation.log' -SimpleMatch -Pattern $bench.Marker -Quiet
        $failed = Select-String -LiteralPath 'simulation.log' -Pattern 'Fatal:|FATAL:|ERROR:|ERROR \[' -Quiet
        if (!$passed -or $failed) { throw "Assertions or completion marker failed for $($bench.Name); see $benchRoot\simulation.log" }
        $results += [ordered]@{ testbench = $bench.Name; result = 'PASS'; log = (Join-Path $benchRoot 'simulation.log') }
        Write-Host "PASS $($bench.Name)"
    } finally {
        Pop-Location
    }
}
[ordered]@{
    result = 'PASS'
    purpose = 'Camera-only detection, capture, preview and diagnostic status verification'
    physical_hardware_test = $false
    simulator = 'AMD Vivado XSim'
    completed_utc = [DateTime]::UtcNow.ToString('o')
    testbench_count = $results.Count
    preprocessing_included = [bool]$IncludePreprocess
    tests = $results
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Write-Host "CAMERA_SIMULATION_SUITE_PASS tests=$($results.Count)"
Write-Host $summaryPath
