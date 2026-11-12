@echo off
setlocal
cd /d "%~dp0verilog-uart"
start "" "%~dp0.venv\Scripts\pythonw.exe" "%~dp0verilog-uart\host\uploader.py"
