@echo off
chcp 65001 >nul
set PYTHONIOENCODING=utf-8
echo ============================================
echo  Monitor Serie - COMEDOR (COM3 @ 115200)
echo  Cierra esta ventana antes de volver a subir.
echo ============================================
echo.
"%USERPROFILE%\.platformio\penv\Scripts\pio.exe" device monitor -p COM3 -b 115200
pause
