@echo off
setlocal
cd /d "%~dp0verilog-camera"
call "C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat" -mode batch -source "%~dp0verilog-camera\scripts\program_camera_test.tcl"
pause
