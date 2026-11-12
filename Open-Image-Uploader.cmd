@echo off
cd /d "%~dp0"
"%~dp0.venv\Scripts\python.exe" "%~dp0scripts\upload_image.py" %*
if errorlevel 1 pause
