@echo off
setlocal
cd /d "%~dp0verilog-uart"
call "C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat" -mode gui -source "%~dp0verilog-uart\scripts\create_project.tcl"
