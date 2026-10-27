@echo off
rem Allow the Quest Cast control server through Windows Firewall.
rem Run once (the script asks for elevation itself). Port can be overridden:
rem   allow-firewall.cmd 47900
setlocal
set PORT=%~1
if "%PORT%"=="" set PORT=47801

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Asking for administrator rights...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%PORT%' -Verb RunAs"
    exit /b
)

netsh advfirewall firewall delete rule name="QuestCast Control" >nul 2>&1
netsh advfirewall firewall add rule name="QuestCast Control" dir=in action=allow protocol=TCP localport=%PORT% profile=any description="Quest Cast LAN control server"
if %errorlevel% equ 0 (
    echo OK: inbound TCP %PORT% is allowed.
) else (
    echo FAILED: could not create the firewall rule.
)
echo.
pause
