@echo off
setlocal
cd /d "%~dp0verilog-camera"
call "C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat" -mode gui -source "%~dp0verilog-camera\scripts\create_camera_test.tcl"
