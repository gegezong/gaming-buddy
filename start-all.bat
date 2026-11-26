@echo off
chcp 65001 >nul
title GameMate-Agent Launcher
cd /d "%~dp0"

REM ==========================================================
REM  GameMate-Agent  一键启动
REM  用法: 双击本文件即可(或在命令行执行 start-all.bat)
REM ==========================================================

set MYSQL_HOME=D:\mysql\mysql-8.0.46-winx64
set MYSQL_INI=D:\mysql\my.ini

echo.
echo  ==========================================================
echo    GameMate-Agent   游戏陪玩交易多智能体平台
echo    一键启动
echo  ==========================================================
echo.

REM ---------- 1) MySQL ----------
netstat -ano | findstr "LISTENING" | findstr ":3306 " >nul
if errorlevel 1 (
    if exist "%MYSQL_HOME%\bin\mysqld.exe" (
        echo  [1/3] MySQL      启动中... ^(新窗口, 首次启动约需 10 秒^)
        start "GameMate-MySQL" cmd /k ""%MYSQL_HOME%\bin\mysqld.exe" --defaults-file="%MYSQL_INI%" --console"
    ) else (
        echo  [1/3] MySQL      [!] 未找到 %MYSQL_HOME%
        echo                 请先按 docs\本地启动指南.md 安装 MySQL, 或手动启动后重试
    )
) else (
    echo  [1/3] MySQL      已在运行 ^(端口 3306^), 跳过
)

REM ---------- 2) 后端 ----------
netstat -ano | findstr "LISTENING" | findstr ":8080 " >nul
if errorlevel 1 (
    if exist "fastapi\.venv\Scripts\python.exe" (
        echo  [2/3] 后端服务    启动中... ^(新窗口, 端口 8080^)
        start "GameMate-Backend" cmd /k "cd fastapi && .venv\Scripts\python.exe -m uvicorn main:app --host 0.0.0.0 --port 8080 --use-colors"
    ) else (
        echo  [2/3] 后端服务    [!] 未找到虚拟环境
        echo                 请先执行: cd fastapi ^&^& python -m venv .venv ^&^& pip install -r requirements.txt
    )
) else (
    echo  [2/3] 后端服务    已在运行 ^(端口 8080^), 跳过
)

REM ---------- 3) 前端 ----------
netstat -ano | findstr "LISTENING" | findstr ":90 " >nul
if errorlevel 1 (
    if exist "vue\node_modules" (
        echo  [3/3] 前端服务    启动中... ^(新窗口, 端口 90^)
        start "GameMate-Frontend" cmd /k "cd vue && npm run dev"
    ) else (
        echo  [3/3] 前端服务    [!] 未找到 node_modules
        echo                 请先执行: cd vue ^&^& npm install
    )
) else (
    echo  [3/3] 前端服务    已在运行 ^(端口 90^), 跳过
)

echo.
echo  等待后端就绪...
set /a WAIT=0
:wait_loop
set /a WAIT+=1
netstat -ano | findstr "LISTENING" | findstr ":8080 " >nul
if errorlevel 1 (
    if %WAIT% lss 30 (
        timeout /t 1 >nul
        goto wait_loop
    )
)

echo.
echo  ==========================================================
echo    启动完成
echo  ==========================================================
echo    前端页面   http://localhost:90
echo    接口文档   http://localhost:8080/docs
echo.
echo    管理员登录   admin  / admin        ^(管理后台^)
echo    普通用户登录 张三  / 123456        ^(C 端商城 + AI 助手^)
echo.
echo    停止全部服务: 双击 stop-all.bat
echo  ==========================================================
echo.

start "" "http://localhost:90/"
endlocal
