# Convert-DrcsJsonToAmatsukaze

NHKで公開されている DRCS外字データ `drcs-subst.json` を、エンコードソフト「Amatsukaze」が利用できる形式（DRCS外字 36x36 BMP画像 + マップ定義ファイル）に変換・マージするツールです。

## 使い方
1. `Convert-DrcsJsonToAmatsukaze.bat` を実行します。
2. 自動的にJSONがダウンロードされ、変換処理が行われます。
3. `drcs_output` フォルダに **DRCS外字**（BMP）と **drcs_map.txt** が出力されます。

## 必要要件
* Windows PowerShell 5.1 以上
