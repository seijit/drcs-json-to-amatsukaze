:: 文字コード設定 
chcp 65001 > nul

:: 自身と同名のps1スクリプトに、ドラッグされた引数を渡して実行 
title %~nx0
set "SELF_FILE_NAME=%~n0"
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0%SELF_FILE_NAME%.ps1" %*

pause
