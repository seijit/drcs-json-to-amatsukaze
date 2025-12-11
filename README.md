# Convert-DrcsJsonToAmatsukaze

NHKで公開されている DRCS外字データ `drcs-subst.json` を、エンコードソフト「Amatsukaze」が利用できる形式（DRCS外字 36x36 BMP画像 + マップ定義ファイル）に変換・マージするツールです。

## 使い方
1. `Convert-DrcsJsonToAmatsukaze.bat` を実行します。
2. 自動的にJSONがダウンロードされ、変換処理が行われます。
3. `drcs_output` フォルダに **DRCS外字**（BMP）と **drcs_map.txt** が出力されます。

## 注意
* **実行できない場合**: `Convert-DrcsJsonToAmatsukaze.ps1` のプロパティを開き、セキュリティの「許可する」にチェックを入れてください。
* **既存マップへの追加**: 既存のマップ定義ファイルを引き継ぎたい場合は、バッチファイル (`.bat`) 内のコメントを参照してください。

## 必要要件
* Windows PowerShell 5.1 以上