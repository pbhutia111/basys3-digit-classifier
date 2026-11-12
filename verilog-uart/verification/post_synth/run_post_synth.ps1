$ErrorActionPreference='Stop'
$vivadoBin='C:\AMDDesignTools\2026.1\Vivado\bin'
$simRoot=$PSScriptRoot
foreach ($name in @('sample_pixels.mem','sample_expected.mem')) {
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $simRoot) $name) -Destination (Join-Path $simRoot $name) -Force
}
Push-Location -LiteralPath $simRoot
try {
    & (Join-Path $vivadoBin 'vivado.bat') -mode batch -source export_netlist.tcl -log export.log -journal export.jou *> export_console.log
    if ($LASTEXITCODE -ne 0) { throw 'Netlist export failed' }
    & (Join-Path $vivadoBin 'xvlog.bat') basys3_mnist_funcsim.v tb_post_synth.v *> compile.log
    if ($LASTEXITCODE -ne 0) { throw 'Post-synth xvlog failed' }
    # Port-only checks need no internal debug instrumentation.
    & (Join-Path $vivadoBin 'xelab.bat') -L unisims_ver --debug off --snapshot post_synth_sim work.tb_post_synth work.glbl *> elaborate.log
    if ($LASTEXITCODE -ne 0) { throw 'Post-synth xelab failed' }
    & (Join-Path $vivadoBin 'xsim.bat') post_synth_sim --runall --onfinish quit *> simulation.log
    if ($LASTEXITCODE -ne 0) { throw 'Post-synth xsim failed' }
    $passed=Select-String -LiteralPath simulation.log -Pattern 'POST_SYNTH_PASS:' -Quiet
    $failed=Select-String -LiteralPath simulation.log -Pattern 'FAIL|Fatal:|FATAL:|ERROR:' -Quiet
    if (!$passed -or $failed) { throw 'Post-synth functional check failed; see simulation.log' }
    Get-Content -LiteralPath simulation.log | Select-String -Pattern 'POST_SYNTH_'
} finally {
    Pop-Location
}
