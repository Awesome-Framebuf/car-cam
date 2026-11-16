@echo off
rem WiFi-Dongle-Install for Windows: installs the AIC8800D80 (AX900) dongle driver.
rem Uses a driver\ folder next to this script if present; otherwise looks for the
rem driver on the dongle's own CD drive (any drive D: to Z:, two levels deep).
rem The driver itself is the vendor's and is not shipped with this script.
setlocal EnableDelayedExpansion

net session >nul 2>&1
if errorlevel 1 (
  echo Asking for administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

set FOUND=0
if exist "%~dp0driver\" (
  echo Installing the driver from "%~dp0driver"...
  pnputil /add-driver "%~dp0driver\*.inf" /subdirs /install
  set FOUND=1
  goto done
)

echo Looking for the dongle's driver on drives D: to Z:...
for %%D in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
  if exist %%D:\ (
    for %%F in (%%D:\*.inf) do call :check "%%F"
    for /d %%S in (%%D:\*) do for %%F in ("%%S\*.inf") do call :check "%%F"
    for /d %%S in (%%D:\*) do for /d %%T in ("%%S\*") do for %%F in ("%%T\*.inf") do call :check "%%F"
  )
)

:done
echo.
if "!FOUND!"=="0" (
  echo No AIC8800 driver was found. Plug in the dongle, wait for its CD drive to
  echo appear, and run this again, or run the setup program on that CD drive.
) else (
  echo Done. Unplug and replug the dongle.
)
pause
exit /b

:check
findstr /i /m "VID_A69C VID_368B AIC" %1 >nul 2>&1
if errorlevel 1 exit /b
echo Installing %~1
pnputil /add-driver %1 /install
set FOUND=1
exit /b
