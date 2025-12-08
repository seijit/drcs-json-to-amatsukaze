<#
.SYNOPSIS
    drcs-subst.json を Amatsukaze 互換の BMP と drcs_map.txt に変換・マージします。
    v22: 日本語維持 + PowerShell 5.1 対応 (C#構文修正 & TLS1.2有効化)。

.DESCRIPTION
    NHKなどで公開されている DRCS 代替文字定義 (JSON) を読み込み、
    Amatsukaze が利用できる形式 (36x36 BMP画像 + マップファイル) に変換します。
    
    既存のマップファイルを指定した場合は、その内容を読み込み、
    未登録の文字のみを追記した新しいマップファイルを出力します（マージモード）。
    既存のファイル自体を上書き更新することはありません。

.PARAMETER ExistingMapPath
    マージ元となる既存のマップファイルのパス。
    指定すると、そのファイルに記載済みのハッシュ値はスキップされます。
    省略した場合は、新規作成モードとなります。

.PARAMETER JsonPath
    入力となるJSONデータの場所（URL または ローカルファイルパス）。
    省略時は NHK のアーカイブURLから自動ダウンロードします。

.PARAMETER OutputDir
    ファイルの出力先フォルダ。デフォルトは "drcs_output" です。

.PARAMETER OutputMapFileName
    出力するマップファイルの名前。デフォルトは "drcs_map.txt" です。

.EXAMPLE
    # 全自動実行 (Webから取得し、マージせず新規作成)
    .\Convert.ps1

.EXAMPLE
    # 既存環境への追加 (既存ファイルを指定してマージ)
    .\Convert.ps1 "C:\Amatsukaze\drcs\drcs_map.txt"
#>

[CmdletBinding()]
param(
    # マージする既存のマップファイルパス
    [Parameter(Position=0)]
    [string]$ExistingMapPath = $null,

    # 入力JSON (URL または ファイルパス)
    [Parameter(Position=1)]
    [string]$JsonPath = "https://archive.hsk.st.nhk/npd3/config/drcs-subst.json",

    # 出力フォルダ
    [Parameter(Position=2)]
    [string]$OutputDir = "drcs_output",

    # 出力ファイル名
    [Parameter(Position=3)]
    [string]$OutputMapFileName = "drcs_map.txt"
)

# 定数定義: C#ロジック (Amatsukaze互換処理)
Set-Variable -Name CSHARP_CODE -Option Constant -Value @'
using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Collections.Generic;

public class AmatsukazeLogic
{
    // Amatsukaze標準パレット (Index 0:Transparent, ..., 3:White)
    private static readonly byte[] PALETTE = new byte[64] {
        255,255,255,0,  170,170,170,0,  85,85,85,0,  0,0,0,0,
        0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
        0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
        0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0
    };

    public class DrcsResult {
        public string Hash;
        public byte[] BmpBytes;
        public bool Success;
        public string ErrorMessage;
    }

    public static DrcsResult Process(string base64String)
    {
        var res = new DrcsResult { Success = false };
        try {
            if (string.IsNullOrEmpty(base64String)) {
                res.ErrorMessage = "Empty data";
                return res;
            }

            byte[] rawData = Convert.FromBase64String(base64String);
            
            // 1. 解像度とビット深度を推定
            // PowerShell 5.1 (C# 5.0) 互換のため、out変数を事前に宣言
            int w, h, depth;
            EstimateFormat(rawData.Length, out w, out h, out depth);

            // 2. キャンバス作成 (Amatsukaze仕様: 左上配置 / 36x36)
            byte[,] canvas = CreateCanvas(rawData, w, h, depth);

            // 3. ハッシュ計算 (Amatsukaze仕様: 2bitモード)
            res.Hash = CalculateAmatsukazeMD5(canvas);

            // 4. BMPバイナリ生成
            res.BmpBytes = CreateAmatsukazeBMP(canvas);
            
            res.Success = true;

        } catch (Exception ex) {
            res.ErrorMessage = ex.Message;
        }
        return res;
    }

    private static void EstimateFormat(int len, out int w, out int h, out int depth)
    {
        w = 36; h = 36; depth = 2; // デフォルト(標準全角)

        // 代表的なサイズの判定
        if (len == 324)      { w = 36; h = 36; depth = 2; }
        else if (len == 162) { w = 18; h = 36; depth = 2; }
        else if (len == 225) { w = 30; h = 30; depth = 2; }
        else if (len == 113) { w = 30; h = 30; depth = 1; }
        else if (len == 72)  { w = 16; h = 18; depth = 2; }
        else if (len == 57)  { w = 15; h = 30; depth = 1; }
        else {
            // その他のサイズ: 容量から計算
            if ((len * 4) % 36 == 0) {
                h = 36;
                w = (len * 4) / 36;
            } else if (Math.Abs((double)len * 4 / 25.0 - Math.Round((double)len * 4 / 25.0)) < 0.5) {
                w = 25;
                h = (int)Math.Round((double)len * 4 / 25.0);
            } else {
                 // フォールバック
                 h = 36;
                 w = (len * 4) / 36;
                 if (w == 0) w = 1;
            }
        }
    }

    private static byte[,] CreateCanvas(byte[] rawData, int w, int h, int depth)
    {
        byte[,] canvas = new byte[36, 36]; // 0(透明)で初期化
        int bitIndex = 0;
        int len = rawData.Length;

        // 左上(0,0)から描画
        for (int y = 0; y < h && y < 36; y++) {
            for (int x = 0; x < w && x < 36; x++) {
                int val = 0;
                if (depth == 2) {
                    // 2bit (4px/byte)
                    int byteIdx = bitIndex / 4;
                    int bitShift = 6 - ((bitIndex % 4) * 2);
                    if (byteIdx < len) val = (rawData[byteIdx] >> bitShift) & 0x03;
                } else {
                    // 1bit (8px/byte)
                    int byteIdx = bitIndex / 8;
                    int bitShift = 7 - (bitIndex % 8);
                    if (byteIdx < len) {
                        int bit = (rawData[byteIdx] >> bitShift) & 0x01;
                        val = (bit == 1) ? 3 : 0; // 1->白(3), 0->透明(0)
                    }
                }
                canvas[y, x] = (byte)val;
                bitIndex++;
            }
        }
        return canvas;
    }

    private static string CalculateAmatsukazeMD5(byte[,] canvas)
    {
        int nWidth = 36;
        int nHeight = 36;
        // Gradation 4 (2bit) バッファサイズ
        int packedSize = (nWidth * nHeight + 3) / 4; 
        byte[] bData = new byte[packedSize]; 
        
        // Amatsukaze仕様: Bottom-Up走査
        for (int y = nHeight - 1; y >= 0; y--) {
            for (int x = 0; x < nWidth; x++) {
                int nPix = canvas[y, x];
                int nPos = y * nWidth + x;
                // 2bit Packing
                int shift = (3 - (nPos % 4)) * 2;
                bData[nPos / 4] |= (byte)(nPix << shift);
            }
        }
        using (MD5 md5 = MD5.Create())
        {
            byte[] hashBytes = md5.ComputeHash(bData, 0, packedSize);
            return BitConverter.ToString(hashBytes).Replace("-", "").ToUpper();
        }
    }

    private static byte[] CreateAmatsukazeBMP(byte[,] canvas)
    {
        int w = 36;
        int h = 36;
        int stride = 20; // 36px 4bit (18byte + 2padding)
        int pixelDataSize = stride * h;
        int fileSize = 14 + 40 + 64 + pixelDataSize;

        using (var ms = new MemoryStream(fileSize))
        using (var writer = new BinaryWriter(ms))
        {
            // BMP Header
            writer.Write((ushort)0x4D42); // BM
            writer.Write((uint)fileSize);
            writer.Write((ushort)0);
            writer.Write((ushort)0);
            writer.Write((uint)(14 + 40 + 64)); // Offset

            // Info Header
            writer.Write((uint)40);
            writer.Write((int)w);
            writer.Write((int)h);
            writer.Write((ushort)1);
            writer.Write((ushort)4); // 4bit color
            writer.Write((uint)0);
            writer.Write((uint)pixelDataSize);
            writer.Write((int)0);
            writer.Write((int)0);
            writer.Write((uint)0);
            writer.Write((uint)0);

            // Palette
            writer.Write(PALETTE);

            // Pixel Data (Bottom-Up)
            byte[] buffer = new byte[pixelDataSize];
            for (int y = 0; y < h; y++) {
                int srcY = (h - 1) - y; // 上下反転
                int rowOffset = y * stride;
                for (int x = 0; x < w; x+=2) {
                    byte p1 = canvas[srcY, x];
                    byte p2 = (x + 1 < w) ? canvas[srcY, x + 1] : (byte)0;
                    buffer[rowOffset + (x / 2)] = (byte)((p1 << 4) | (p2 & 0x0F));
                }
            }
            writer.Write(buffer);
            return ms.ToArray();
        }
    }
}
'@

# --- 関数定義 ---

function Initialize-Environment {
    # C#コードのコンパイル
    try {
        Add-Type -TypeDefinition $CSHARP_CODE -Language CSharp
    } catch {
        if (-not $_.Exception.Message.Contains("AmatsukazeLogic")) {
            throw "C#コードのコンパイルに失敗しました: $($_.Exception.Message)"
        }
    }
    
    # 実行ログファイルパスの生成 (スクリプト名.log)
    # 関数内から $MyInvocation.MyCommand.Name を呼ぶと関数名になるため、
    # $PSCommandPath (スクリプトのフルパス) からファイル名を取得する
    $scriptName = if ($PSCommandPath) { 
        [System.IO.Path]::GetFileName($PSCommandPath) 
    } else { 
        "Convert.ps1" 
    }
    return [System.IO.Path]::ChangeExtension($scriptName, ".log")
}

function Get-JsonData {
    param([string]$Path)
    
    # Windows PowerShell (5.1) 向けのTLS設定を追加
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Host "JSONデータを取得しています: $Path"
    
    if ($Path -match "^https?://") {
        try {
            return Invoke-RestMethod -Uri $Path -Method Get
        } catch {
            throw "Webからのダウンロードに失敗しました: $($_.Exception.Message)"
        }
    } elseif (Test-Path $Path) {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        throw "指定されたJSONファイルが見つかりません: $Path"
    }
}

function Load-ExistingMap {
    param([string]$Path)
    
    $map = @{}
    $lines = [System.Collections.Generic.List[string]]::new()
    
    if (-not [string]::IsNullOrEmpty($Path) -and (Test-Path $Path)) {
        Write-Host "既存のマップファイルを読み込んでいます: $Path"
        
        # 配列として一括取得
        $rawLines = Get-Content -LiteralPath $Path -Encoding UTF8
        if ($rawLines) {
            # Listに追加 (オーバーロードエラー回避のため AddRange を使用)
            $lines.AddRange([string[]]$rawLines)
            
            # 重複チェック用マップの構築
            foreach ($line in $rawLines) {
                if ($line -match "^([0-9A-Fa-f]{32})=(.+)$") {
                    $hash = $matches[1].ToUpper()
                    if (-not $map.ContainsKey($hash)) {
                        $map[$hash] = $matches[2]
                    }
                }
            }
        }
        Write-Host "既存エントリー数: $($map.Count)"
    }
    return @{ Map = $map; Lines = $lines }
}

function Process-Conversion {
    param($JsonData, $ExistingMapData, $OutputDir, $LogPath)

    $total = $JsonData.map.Count
    $current = 0
    $added = 0
    $skipped = 0
    $logBuffer = @()

    # 出力用リストの初期化 (既存の内容をコピー)
    $finalLines = [System.Collections.Generic.List[string]]::new()
    if ($ExistingMapData.Lines -and $ExistingMapData.Lines.Count -gt 0) {
        $finalLines.AddRange($ExistingMapData.Lines)
    }

    $currentMap = $ExistingMapData.Map # 重複チェック用参照

    Write-Host "変換とマージ処理を開始します ($total 件)..."

    foreach ($item in $JsonData.map) {
        $current++
        if ($current % 500 -eq 0) {
            Write-Progress -Activity "処理中" -Status "$current / $total ($added 追加, $skipped スキップ)" -PercentComplete (($current / $total) * 100)
            Flush-LogBuffer -Path $LogPath -Buffer ([ref]$logBuffer)
        }

        if (-not $item.drcs -or -not $item.alternative) { continue }

        # C#ロジック呼び出し (変換処理)
        $result = [AmatsukazeLogic]::Process($item.drcs)

        if ($result.Success) {
            $hash = $result.Hash
            $char = $item.alternative
            
            # 実行ログへのバッファリング
            $logBuffer += "$hash=$char [BASE64: $($item.drcs)]"

            # 重複チェック
            if ($currentMap.ContainsKey($hash)) {
                $skipped++
            } else {
                # 新規登録
                $finalLines.Add("$hash=$char")
                $currentMap[$hash] = $char
                
                # BMP保存
                $bmpPath = Join-Path $OutputDir "$hash.bmp"
                [System.IO.File]::WriteAllBytes($bmpPath, $result.BmpBytes)
                
                $added++
            }
        }
    }
    
    # 残りのログ書き出し
    Flush-LogBuffer -Path $LogPath -Buffer ([ref]$logBuffer)
    Write-Progress -Completed -Activity "完了"
    
    return @{
        Lines = $finalLines
        Added = $added
        Skipped = $skipped
    }
}

function Flush-LogBuffer {
    param($Path, [ref]$Buffer)
    if ($Buffer.Value.Count -gt 0) {
        Add-Content -Path $Path -Value $Buffer.Value -Encoding UTF8
        $Buffer.Value = @()
    }
}

# --- メイン処理 ---

try {
    # 1. 初期化 (コンパイル・ログ準備)
    $logFilePath = Initialize-Environment
    if (Test-Path $logFilePath) { Clear-Content $logFilePath }
    
    # 2. 出力先の準備
    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

    # 3. データの読み込み
    $jsonData = Get-JsonData -Path $JsonPath
    if (-not $jsonData -or -not $jsonData.map) { throw "有効なJSONデータが読み込めませんでした。" }

    $existingData = Load-ExistingMap -Path $ExistingMapPath

    # 4. 変換・マージ実行
    $result = Process-Conversion `
        -JsonData $jsonData `
        -ExistingMapData $existingData `
        -OutputDir $OutputDir `
        -LogPath $logFilePath

    # 5. 結果ファイルの書き出し
    $finalMapPath = Join-Path $OutputDir $OutputMapFileName
    [System.IO.File]::WriteAllLines($finalMapPath, $result.Lines, [System.Text.Encoding]::UTF8)

    Write-Host "`n処理完了！" -ForegroundColor Green
    Write-Host "----------------------------------------"
    Write-Host "出力マップ: $finalMapPath"
    Write-Host "実行ログ  : $logFilePath"
    Write-Host "ステータス: 追加 $($result.Added) 件, 重複スキップ $($result.Skipped) 件"
    Write-Host "----------------------------------------"

} catch {
    Write-Error "エラーが発生しました: $_"
    exit 1
}