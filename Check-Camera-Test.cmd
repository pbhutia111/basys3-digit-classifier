@echo off
setlocal
cd /d "%~dp0verilog-camera"
if not exist "%~dp0.venv\Scripts\python.exe" (
    echo Project Python was not found at "%~dp0.venv\Scripts\python.exe".
    pause
    exit /b 2
)
"%~dp0.venv\Scripts\python.exe" "%~dp0verilog-camera\host\camera_status.py" %*
set "camera_status_exit=%ERRORLEVEL%"
echo.
pause
exit /b %camera_status_exit%
