@echo off
setlocal
title Outride - Build Windows EXE
cd /d "%~dp0"

where flutter >nul 2>nul
if errorlevel 1 (
  echo [ERROR] flutter was not found on PATH.
  echo Install the Flutter SDK and add its bin folder to your user PATH,
  echo then double-click this script again.
  pause
  exit /b 1
)

echo === Building Outride release EXE ===
echo This takes a few minutes on the first run. Leave this window open.
echo.
call flutter build windows --release
if errorlevel 1 (
  echo.
  echo [ERROR] The build failed. Copy the red text above and send it to Spark.
  pause
  exit /b 1
)

if not exist "build\windows\x64\runner\Release\outride.exe" (
  echo [ERROR] Build finished but outride.exe was not found where expected.
  pause
  exit /b 1
)

echo.
echo === Packaging portable zip on your Desktop ===
for /f "delims=" %%D in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "[Environment]::GetFolderPath('Desktop')"') do set DESKTOPDIR=%%D
if not defined DESKTOPDIR set DESKTOPDIR=%USERPROFILE%\Desktop
powershell -NoProfile -ExecutionPolicy Bypass -Command "Compress-Archive -Path '%CD%\build\windows\x64\runner\Release\*' -DestinationPath '%DESKTOPDIR%\outride_windows.zip' -Force"
if errorlevel 1 (
  echo [ERROR] Zipping failed, but the exe itself built fine.
  echo You can find it at: %CD%\build\windows\x64\runner\Release\outride.exe
  pause
  exit /b 1
)

echo.
echo DONE. Your portable app is on the Desktop: outride_windows.zip
echo Unzip it anywhere and run outride.exe. Your settings carry over
echo because they are stored per Windows user, not per folder.
echo.
echo NOTE: the exe is unsigned, so SmartScreen may warn about an
echo unknown publisher on first launch. Click "More info", then "Run anyway".
pause
