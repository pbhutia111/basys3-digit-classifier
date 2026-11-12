$ErrorActionPreference = 'Stop'
$verificationRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent $verificationRoot
$workspaceRoot = Split-Path -Parent $projectRoot
$upstreamRoot = Join-Path $workspaceRoot 'repos\neural-net-on-fpga\hdl'
$vivadoBin = 'C:\AMDDesignTools\2026.1\Vivado\bin'
$simRoot = Join-Path $verificationRoot 'sim'
New-Item -ItemType Directory -Path $simRoot -Force | Out-Null

foreach ($fixtureName in @('test_pixels.mem', 'test_expected.mem', 'test_hidden.mem', 'test_logits.mem')) {
    Copy-Item -LiteralPath (Join-Path $verificationRoot $fixtureName) -Destination (Join-Path $simRoot $fixtureName) -Force
}
foreach ($weightName in @('fc1_weights.mem', 'fc1_bias.mem', 'fc2_weights.mem', 'fc2_bias.mem')) {
    Copy-Item -LiteralPath (Join-Path (Join-Path $upstreamRoot 'weights') $weightName) -Destination (Join-Path $simRoot $weightName) -Force
}

Push-Location -LiteralPath $simRoot
try {
    & (Join-Path $vivadoBin 'xvlog.bat') --sv (Join-Path $upstreamRoot 'src\weight_rom.v') (Join-Path $upstreamRoot 'src\inference_engine.v') (Join-Path $verificationRoot 'tb_inference_reference.v') *> compile.log
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed; see verification/sim/compile.log' }
    & (Join-Path $vivadoBin 'xelab.bat') --debug typical --snapshot inference_reference_sim work.tb_inference_reference *> elaborate.log
    if ($LASTEXITCODE -ne 0) { throw 'xelab failed; see verification/sim/elaborate.log' }
    & (Join-Path $vivadoBin 'xsim.bat') inference_reference_sim --runall --onfinish quit *> simulation.log
    if ($LASTEXITCODE -ne 0) { throw 'xsim failed; see verification/sim/simulation.log' }
    $passed = Select-String -LiteralPath (Join-Path $simRoot 'simulation.log') -Pattern 'REFERENCE_SIM_PASS predictions=20 hidden=640 logits=200' -Quiet
    $fatalFound = Select-String -LiteralPath (Join-Path $simRoot 'simulation.log') -Pattern 'Fatal:|FATAL:|ERROR:' -Quiet
    if (!$passed -or $fatalFound) { throw 'RTL reference verification did not pass; see verification/sim/simulation.log' }
    Copy-Item -LiteralPath (Join-Path $simRoot 'rtl_reference_report.json') -Destination (Join-Path $verificationRoot 'rtl_reference_report.json') -Force
    Get-Content -LiteralPath (Join-Path $simRoot 'rtl_reference_report.json')
} finally {
    Pop-Location
}
