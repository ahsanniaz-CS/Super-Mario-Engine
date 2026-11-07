@echo off
rem Assembles mario.asm into MARIO.COM (flat binary, DOS .COM format)
nasm -f bin mario.asm -o MARIO.COM
if errorlevel 1 goto failed
echo Build OK: MARIO.COM
goto end
:failed
echo Build FAILED
:end
