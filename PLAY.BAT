@echo off
rem PLAY.BAT - builds MARIO.COM from mario.asm and starts the game in DOSBox.
rem Keep this file in the same folder as mario.asm and MARIO.CONF.
cd /d "%~dp0"

nasm -f bin mario.asm -o MARIO.COM
if errorlevel 1 goto failed

set DOSBOX=C:\Program Files (x86)\DOSBox-0.74\DOSBox.exe
if not exist "%DOSBOX%" set DOSBOX=C:\Program Files\DOSBox-0.74\DOSBox.exe
if not exist "%DOSBOX%" goto nodosbox

"%DOSBOX%" -conf MARIO.CONF
goto end

:nodosbox
echo DOSBox was not found. Edit the DOSBOX path inside PLAY.BAT.
pause
goto end

:failed
echo Build FAILED - the game was not started.
pause

:end
