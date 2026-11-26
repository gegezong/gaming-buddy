@echo off
chcp 65001 >nul
title GameMate-Agent Stopper
cd /d "%~dp0"

echo.
echo  正在停止 GameMate-Agent 相关服务...
echo.

for %%P in (8080 90 3306) do (
    netstat -ano | findstr "LISTENING" | findstr ":%%P " >nul
    if not errorlevel 1 (
        for /f "tokens=5" %%a in ('netstat -ano ^| findstr "LISTENING" ^| findstr ":%%P "') do (
            echo    停止端口 %%P ^(PID %%a^)
            taskkill /PID %%a /F >nul 2>&1
        )
    ) else (
        echo    端口 %%P 未在运行
    )
)

echo.
echo  全部服务已停止。
echo  注: MySQL 为强制结束, 下次启动会自动执行崩溃恢复(正常情况下无损)。
echo.
timeout /t 3 >nul
endlocal
