@echo off
setlocal
cd /d "%~dp0"
set "SCRIPT=%~dp0MEHEN_Mission_Control.ps1"
set "CLEAN=%~dp0CLEAN_BOTH_AUPS.ps1"

echo ============================================================
echo MEHEN Mission Control v1.0.42 HARD-FPRIME-READY
echo ============================================================
echo Folder: %~dp0
echo Script: %SCRIPT%
echo.
if not exist "%SCRIPT%" (
  echo ERROR: MEHEN_Mission_Control.ps1 not found.
  pause
  exit /b 1
)

echo PRELAUNCH CLEAN:
echo   Before the GUI opens, this batch cleans AUP1 and AUP2.
echo   It kills stale AupZu3, F-Prime GDS/Flask, link agents, and frees ports.
echo   Enter the xilinx password if prompted.
echo.
if exist "%CLEAN%" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%CLEAN%"
) else (
  echo WARNING: CLEAN_BOTH_AUPS.ps1 not found. Continuing without prelaunch clean.
)

echo.
echo Correct button flow:
echo   1. RESET + OPEN F-PRIME
echo   2. CHECK + PRIME F-PRIME
echo   3. Optional: F-PRIME EVENT SET
echo   4. ESTABLISH SECURE CHANNEL
echo   5. SEND AUP1 TO AUP2 or AUP2 TO AUP1
echo   6. RUN FULL DEMO or TAMPER TEST
echo   7. STOP / CLEANUP
echo.
echo Launching GUI now...
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT%"
set "EC=%ERRORLEVEL%"
echo.
echo MEHEN Mission Control exited with code %EC%.
if not "%EC%"=="0" (
  echo Check MEHEN_RUNTIME_ERROR.txt in this folder.
)
pause
exit /b %EC%
