@echo off
REM -----------------------------------------------------------------------------
REM Amatsukaze用 DRCS変換スクリプト起動ランチャー 
REM -----------------------------------------------------------------------------
REM 
REM 【概要】 
REM  同階層にある同名のPowerShellスクリプトを実行します。 
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
REM     [例A] 既存のマップファイルを引き継いで差分更新する場合: 
REM       Convert-DrcsJsonToAmatsukaze.bat -ExistingMapPath "C:\amatsukaze\drcs\drcs_map.txt"
REM       Convert-DrcsJsonToAmatsukaze.bat "C:\amatsukaze\drcs\drcs_map.txt"
REM
REM     [例B] 出力先フォルダ名を変更する場合 (※フォルダは存在しないこと): 
REM       Convert-DrcsJsonToAmatsukaze.bat -OutputDir "drcs_v2"
REM
REM     [例C] SD放送やワンセグ(低画質)のデータも含める場合: 
REM       Convert-DrcsJsonToAmatsukaze.bat -IncludeNonHD
REM
REM -----------------------------------------------------------------------------

:: 文字コード設定 
chcp 65001 > nul

:: 自身と同名のps1スクリプトに、自身に渡された引数をすべて渡して実行 
title %~nx0
set "SELF_FILE_NAME=%~n0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0%SELF_FILE_NAME%.ps1" %*

pause

