@echo off
cd /d "%~dp0"
"%~dp0.venv\Scripts\python.exe" "%~dp0scripts\start_drawing.py" %*
if errorlevel 1 pause
