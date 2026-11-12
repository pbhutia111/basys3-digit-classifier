@echo off
setlocal
cd /d "%~dp0"
if not defined BASYS_VIVADO set "BASYS_VIVADO=C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat"
if not exist "%BASYS_VIVADO%" (
  echo Vivado is not available at "%BASYS_VIVADO%" yet.
  echo Finish installation, or set BASYS_VIVADO to the installed vivado.bat path.
  pause
  exit /b 1
)
call "%BASYS_VIVADO%" -mode gui -source "%~dp0scripts\create_snn_project.tcl"
