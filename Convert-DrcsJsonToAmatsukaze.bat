@echo off
REM -----------------------------------------------------------------------------
REM Amatsukaze用 DRCS変換スクリプト起動ランチャー
REM -----------------------------------------------------------------------------
REM 
REM 【概要】
REM  同階層にある 同名のPowerShellScript を実行します。 
REM
REM 【使い方 / Examples】
REM
REM  1. ダブルクリックで実行 (基本)
REM     - デフォルト設定で実行されます。
REM     - 新規フォルダ "drcs_output" が作成され、HD画質(36x36)の外字のみが出力されます。
REM
REM  2. コマンドプロンプトから実行 (オプション指定)
REM     このバッチファイルの後ろにパラメータを付けることで、設定を変更できます。
REM
REM     [例A] SD放送やワンセグ(低画質)のデータも含める場合:
REM       Convert-DrcsJsonToAmatsukaze.bat -IncludeNonHD
REM
REM     [例B] 出力先フォルダ名を変更する場合 (※フォルダは存在しないこと):
REM       Convert-DrcsJsonToAmatsukaze.bat -OutputDir "drcs_v2"
REM
REM     [例C] 既存のマップファイルを引き継いで差分更新する場合:
REM       Convert-DrcsJsonToAmatsukaze.bat -ExistingMapPath "old\drcs_map.txt" -OutputDir "new_drcs"
REM
REM -----------------------------------------------------------------------------

REM スクリプトパスの解決 
set "SELF_FILE_NAME=%~n0"
title %~nx0

echo -------------------------------------------------------
echo  Convert-DrcsJsonToAmatsukaze (Launcher)
echo -------------------------------------------------------
echo  Target Script: %SELF_FILE_NAME%.ps1
echo.

REM コードページを変更 
chcp 65001 > nul

REM PowerShell呼び出し 
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0%SELF_FILE_NAME%.ps1" %*

pause
