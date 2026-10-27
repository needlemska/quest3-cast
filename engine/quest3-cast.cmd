@echo off
rem Wrapper: works even when the shell's execution policy blocks unsigned scripts.
rem   quest3-cast.cmd start | stop | status | install | uninstall
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0quest3-cast.ps1" %*
