@echo off
setlocal EnableExtensions EnableDelayedExpansion
set ROOT=C:\ucsi-builder
set LOG=%ROOT%\build.log
echo START %DATE% %TIME% > "%LOG%"
mountvol >> "%LOG%" 2>&1

call :find_volume ODP_ESP.TAG S ESPROOT
if errorlevel 1 goto fail
call :find_volume ODP_OS.TAG W OSROOT
if errorlevel 1 goto fail

set DISM=%ROOT%\dism\dism.exe
if not exist "%DISM%" (
  echo Missing ARM64 DISM: %DISM% >> "%LOG%"
  goto fail
)

if not exist %OSROOT%\Windows\System32\Config\SYSTEM (
  "%DISM%" /Apply-Image /ImageFile:"%ROOT%\ValidationOS.wim" /Index:1 /ApplyDir:%OSROOT%\ >> "%LOG%" 2>&1
  if errorlevel 1 goto fail

  "%DISM%" /Image:%OSROOT%\ /Add-Driver /Driver:"%ROOT%\drivers" /Recurse /ForceUnsigned >> "%LOG%" 2>&1
  if errorlevel 1 goto fail

  copy /y "%ROOT%\ACPITABL.dat" %OSROOT%\Windows\System32\ACPITABL.dat >> "%LOG%" 2>&1
  if errorlevel 1 goto fail
  mkdir %OSROOT%\ucsi-smoke >> "%LOG%" 2>&1
  copy /y "%ROOT%\ucsi-smoke.exe" %OSROOT%\ucsi-smoke\ucsi-smoke.exe >> "%LOG%" 2>&1
  if errorlevel 1 goto fail
)

mkdir %ESPROOT%\EFI\Microsoft\Boot >> "%LOG%" 2>&1
xcopy "%OSROOT%\Windows\Boot\EFI\*" "%ESPROOT%\EFI\Microsoft\Boot\" /E /I /H /Y >> "%LOG%" 2>&1
if errorlevel 1 goto fail
mkdir %ESPROOT%\EFI\Boot >> "%LOG%" 2>&1
copy /y "%OSROOT%\Windows\Boot\EFI\bootmgfw.efi" "%ESPROOT%\EFI\Boot\bootaa64.efi" >> "%LOG%" 2>&1
if errorlevel 1 goto fail

set BCDEDIT=C:\Windows\System32\bcdedit.exe
set BCD=%ROOT%\target-BCD
del /f /q "%BCD%" >nul 2>&1
"%BCDEDIT%" /createstore "%BCD%" >> "%LOG%" 2>&1
if errorlevel 1 goto fail
"%BCDEDIT%" /store "%BCD%" /create "{bootmgr}" /d "Windows Boot Manager" >> "%LOG%" 2>&1
if errorlevel 1 goto fail
"%BCDEDIT%" /store "%BCD%" /set "{bootmgr}" device partition=%ESPROOT% >> "%LOG%" 2>&1
if errorlevel 1 goto fail
"%BCDEDIT%" /store "%BCD%" /set "{bootmgr}" path \EFI\Microsoft\Boot\bootmgfw.efi >> "%LOG%" 2>&1
if errorlevel 1 goto fail
set LOADER={01234567-89ab-cdef-0123-456789abcdef}
"%BCDEDIT%" /store "%BCD%" /create %LOADER% /d "ValidationOS" /application osloader >> "%LOG%" 2>&1
if errorlevel 1 goto fail
echo LOADER=%LOADER% >> "%LOG%"
"%BCDEDIT%" /store "%BCD%" /set %LOADER% device partition=%OSROOT% >> "%LOG%" 2>&1
if errorlevel 1 goto fail
"%BCDEDIT%" /store "%BCD%" /set %LOADER% osdevice partition=%OSROOT% >> "%LOG%" 2>&1
if errorlevel 1 goto fail
"%BCDEDIT%" /store "%BCD%" /set %LOADER% path \Windows\System32\winload.efi >> "%LOG%" 2>&1
if errorlevel 1 goto fail
"%BCDEDIT%" /store "%BCD%" /set %LOADER% systemroot \Windows >> "%LOG%" 2>&1
if errorlevel 1 goto fail
"%BCDEDIT%" /store "%BCD%" /set %LOADER% testsigning on >> "%LOG%" 2>&1
if errorlevel 1 goto fail
"%BCDEDIT%" /store "%BCD%" /set %LOADER% debug on >> "%LOG%" 2>&1
if errorlevel 1 goto fail
"%BCDEDIT%" /store "%BCD%" /displayorder %LOADER% /addlast >> "%LOG%" 2>&1
if errorlevel 1 goto fail
"%BCDEDIT%" /store "%BCD%" /default %LOADER% >> "%LOG%" 2>&1
if errorlevel 1 goto fail
"%BCDEDIT%" /store "%BCD%" /timeout 0 >> "%LOG%" 2>&1
if errorlevel 1 goto fail
copy /y "%BCD%" "%ESPROOT%\EFI\Microsoft\Boot\BCD" >> "%LOG%" 2>&1
if errorlevel 1 goto fail

> "%ROOT%\build-result.txt" echo PASS: local image build
echo COMPLETE %DATE% %TIME% >> "%LOG%"
shutdown /s /f /t 5
exit /b 0

:find_volume
set MARKER=%~1
set MOUNTLETTER=%~2
set OUTVAR=%~3
for %%D in (D E F G H I J K L M N O P Q R S T U V X Y Z) do (
  if exist %%D:\%MARKER% (
    set "%OUTVAR%=%%D:"
    echo %OUTVAR%=%%D: >> "%LOG%"
    exit /b 0
  )
)
for /f "tokens=1" %%V in ('mountvol ^| findstr /R /C:"\\\\?\\Volume{"') do (
  mountvol %MOUNTLETTER%: %%V >nul 2>&1
  if exist %MOUNTLETTER%:\%MARKER% (
    set "%OUTVAR%=%MOUNTLETTER%:"
    echo %OUTVAR%=%MOUNTLETTER%: >> "%LOG%"
    exit /b 0
  )
  mountvol %MOUNTLETTER%: /D >nul 2>&1
)
echo Volume marker %MARKER% not found >> "%LOG%"
exit /b 1

:fail
> "%ROOT%\build-result.txt" echo FAIL: errorlevel=%ERRORLEVEL%
echo FAILED %DATE% %TIME% errorlevel=%ERRORLEVEL% >> "%LOG%"
shutdown /s /f /t 5
exit /b 1
