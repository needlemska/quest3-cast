@echo off
rem Launcher for the Quest Cast desktop app.
rem Two variables matter: the engine keeps its runtime files in QUEST3CAST_STATE,
rem and TMP/TEMP are redirected into the project because a GUI started from a
rem restricted context is not always allowed to write into %LOCALAPPDATA%.
setlocal
set HERE=%~dp0
set QUEST3CAST_STATE=%HERE%state
set TMP=%HERE%tmp
set TEMP=%HERE%tmp
if not exist "%QUEST3CAST_STATE%" mkdir "%QUEST3CAST_STATE%"
if not exist "%TMP%" mkdir "%TMP%"
start "" "%HERE%QuestCast\bin\Release\net10.0-windows\QuestCast.exe"
