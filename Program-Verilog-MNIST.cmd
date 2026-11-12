@echo off
setlocal
cd /d "%~dp0verilog-uart"
call "C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat" -mode batch -source "%~dp0verilog-uart\scripts\program.tcl"
pause
