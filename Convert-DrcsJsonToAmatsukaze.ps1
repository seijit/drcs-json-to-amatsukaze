<#
.SYNOPSIS
    drcs-subst.json を解析し、Amatsukaze 用の BMP と drcs_map.txt を生成します。
    (v35.1: Get-JsonData を PowerShell 5.1 に対応)

.DESCRIPTION
    NHK等の放送波に含まれる外字データ(DRCS)の定義ファイル(JSON)を読み込み、
    Amatsukaze互換の形式(MD5ハッシュ名のBMP + マップ定義ファイル)に変換します。

    【AmatsukazeのDRCS仕様について】
    Amatsukazeは、TSファイル内の字幕データ(DRCS)をOCRではなく「画像パターンマッチング」でテキストに置換します。
    そのため、以下の要件を満たす必要があります。
    1. 画像形式: 4bit(16色)インデックスカラーのBMP形式であること。
    2. ファイル名: 画像データから計算された「独自のMD5ハッシュ」であること。
    3. マップ定義: "ハッシュ=置換文字" のリスト(drcs_map.txt)が存在すること。

    【解像度とフィルタリング (HD/SD/ワンセグ)】
    日本のデジタル放送(ARIB STD-B24)では、運用によって文字サイズが異なります。
    - HD放送 (地デジ/BSメイン): 36x36 (最も一般的)
    - SD放送 (サブch/マルチ編成): 30x30
    - ワンセグ (携帯向け): 24x24 / 18x18 など

    Amatsukazeで通常エンコードするのはHD画質がほとんどであるため、
    本スクリプトはデフォルトで「36x36」以外の低解像度データを除外します。

.PARAMETER ExistingMapPath
    既存の drcs_map.txt のパス。
    既存のマップ定義ファイルを指定した場合は、その内容を読み込み、
    未登録の文字のみを追記した新しいマップ定義ファイルを出力します。
    既存のマップ定義ファイルを上書き更新することはありません。
    省略時は既存定義の読み込みを行いません。

.PARAMETER JsonPath
    NHK DRCS変換テーブル(JSON)の URL または ローカルファイルパス。
    省略時のデフォルトは "https://archive.hsk.st.nhk/npd3/config/drcs-subst.json" です。

.PARAMETER OutputDir
    出力先フォルダパス。
    データの混在や破損を防ぐため、「存在しないフォルダパス」を指定する必要があります。
    指定したパスにフォルダが既に存在する場合、スクリプトはエラーで停止します。
    省略時のデフォルトは "drcs_output" です。

.PARAMETER OutputMapFileName
    出力されるマップ定義ファイルのファイル名。
    省略時のデフォルトは "drcs_map.txt" です。

.PARAMETER IncludeNonHD
    [スイッチ] 指定すると、HDサイズ(36x36)以外のデータ(SD/ワンセグ等)も除外せずに全て出力します。
    マルチ編成のサブチャンネルなどをエンコードする場合に指定してください。

.EXAMPLE
    # 1. 基本的な使い方 (推奨)
    # HD放送用(36x36)のデータのみを抽出し、"drcs_output" フォルダ(新規)に出力します。
    .\Convert-DrcsJsonToAmatsukaze.ps1

.EXAMPLE
    # 2. 既存のマップ定義を引き継いだマップ定義ファイルを出力する場合
    # -ExistingMapPath または 第1引数 に既存のマップ定義ファイルを指定します。
    .\Convert-DrcsJsonToAmatsukaze.ps1 -ExistingMapPath "C:\amatsukaze\drcs\drcs_map.txt"
    .\Convert-DrcsJsonToAmatsukaze.ps1 "C:\amatsukaze\drcs\drcs_map.txt"

.EXAMPLE
    # 3. ローカルにあるJSONファイルを使う場合
    # ネットからダウンロードせず、PC内のファイルを読み込みます。
    .\Convert-DrcsJsonToAmatsukaze.ps1 -JsonPath "C:\Downloads\drcs-subst.json"

.EXAMPLE
    # 4. 出力先フォルダ名を変更する場合
    .\Convert-DrcsJsonToAmatsukaze.ps1 -OutputDir "drcs_v2"

.EXAMPLE
    # 5. SD放送やワンセグも含める場合
    # サブチャンネルなどのTSを扱う可能性がある場合に指定します。
    .\Convert-DrcsJsonToAmatsukaze.ps1 -IncludeNonHD
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)] [string]$ExistingMapPath = $null,
    [Parameter(Position=1)] [string]$JsonPath = "https://archive.hsk.st.nhk/npd3/config/drcs-subst.json",
    [Parameter(Position=2)] [string]$OutputDir = "drcs_output",
    [Parameter(Position=3)] [string]$OutputMapFileName = "drcs_map.txt",
    [Parameter(Position=4)]
    # HD(36x36)以外のデータ(SD/ワンセグ等)も含める場合は指定してください
    [switch]$IncludeNonHD = $false
)

# ---------------------------------------------------------
# C# ロジック定義
# PowerShellでは処理速度が不足するため、画像処理とMD5計算はC#で行います。
# ---------------------------------------------------------
Set-Variable -Name CSHARP_CODE -Option Constant -Value @'
using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Collections.Generic;

public class AmatsukazeLogic
{
    // Amatsukaze仕様のパレット定義 (4bitインデックスカラー用)
    // 一般的なWindowsパレットとは異なり、透明度や階調を含んだ特定の並びである必要があります。
    private static readonly byte[] PALETTE = new byte[64] {
        255,255,255,0,  // Index 0: White (or usage specific)
        170,170,170,0,  // Index 1: Light Gray
        85,85,85,0,     // Index 2: Dark Gray
        0,0,0,0,        // Index 3: Black/Transparent
        // Index 4-15: Unused (Zero padding)
        0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
        0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
        0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0
    };

    public class DrcsResult {
        public int Width;
        public int Height;
        public string Hash;
        public byte[] BmpBytes;
        public bool Success;
        public string ErrorMessage;
        public string DetectInfo;
    }

    public static DrcsResult Process(string base64String)
    {
        var res = new DrcsResult { Success = false };
        try {
            if (string.IsNullOrEmpty(base64String)) {
                res.ErrorMessage = "Empty data";
                return res;
            }

            // JSON内のBase64文字列をバイナリ配列に戻す
            byte[] rawData = Convert.FromBase64String(base64String);
            
            // サイズ推定
            // JSONには「幅・高さ」の情報がないため、データ長(Byte数)から
            // ARIB規格で定義されているサイズ(36x36, 30x30等)を逆算・推定します。
            int w, h, depth;
            EstimateFormatWithAnalysis(rawData, out w, out h, out depth);
            
            res.Width = w;
            res.Height = h;

            // ログ出力用の検出情報
            if (rawData.Length == 72) {
                res.DetectInfo = String.Format("Auto-Detect 72bytes -> {0}x{1}", w, h);
            } else {
                res.DetectInfo = String.Format("{0} bytes -> {1}x{2} ({3}bit)", rawData.Length, w, h, depth == 2 ? 2 : 1);
            }

            // 推定したサイズでキャンバス(2次元配列)を作成
            byte[,] canvas = CreateCanvas(rawData, w, h, depth);
            
            // Amatsukaze仕様のMD5ハッシュを計算
            res.Hash = CalculateAmatsukazeMD5(canvas);
            
            // Amatsukaze仕様のBMPバイナリを生成
            res.BmpBytes = CreateAmatsukazeBMP(canvas);
            
            res.Success = true;

        } catch (Exception ex) {
            res.ErrorMessage = ex.Message;
        }
        return res;
    }

    // データ長から解像度を判定するロジック
    private static void EstimateFormatWithAnalysis(byte[] rawData, out int w, out int h, out int depth)
    {
        int len = rawData.Length;
        w = 36; h = 36; depth = 2; // デフォルトはHDサイズ

        // バイト数による明確な判定 (ARIB STD-B24準拠)
        if (len == 324) { w = 36; h = 36; depth = 2; return; } // HD (通常)
        if (len == 162) { w = 18; h = 36; depth = 2; return; } // HD (半角)
        if (len == 225) { w = 30; h = 30; depth = 2; return; } // SD
        if (len == 113) { w = 30; h = 30; depth = 1; return; } // SD (1bit)
        if (len == 96)  { w = 16; h = 24; depth = 2; return; } // OneSeg
        if (len == 57)  { w = 15; h = 30; depth = 1; return; }

        // 72バイトの場合の特殊判定 (12x24 か 16x18 か不明瞭なためパターン解析を行う)
        if (len == 72) {
            double scoreA = AnalyzePattern(rawData, 16, 18, 2);
            double scoreB = AnalyzePattern(rawData, 12, 24, 2);
            if (scoreB >= scoreA * 0.8) { w = 12; h = 24; depth = 2; } 
            else { w = 16; h = 18; depth = 2; }
            return;
        }

        // 上記以外の場合の汎用探索
        int[] commonHeights = new int[] { 36, 30, 24, 18, 20, 16 };
        int[] tryDepths = new int[] { 2, 1 };
        foreach (int d in tryDepths) {
            foreach (int tryH in commonHeights) {
                int tryW = (len * 8) / (tryH * d);
                if (tryW > 0) {
                    int calcLen = (tryW * tryH * d + 7) / 8;
                    if (calcLen == len) { w = tryW; h = tryH; depth = d; return; }
                }
            }
        }
        // フォールバック(推定不可時は36x36とみなす)
        if ((len * 4) % 36 == 0) { h = 36; w = (len * 4) / 36; } 
        else { h = 36; w = (len * 4) / 36; if (w == 0) w = 1; }
    }

    // 画像の「もっともらしさ」を隣接ピクセルの一致度でスコアリングする
    private static double AnalyzePattern(byte[] rawData, int w, int h, int depth)
    {
        byte[,] tempCanvas = CreateCanvas(rawData, w, h, depth); 
        double score = 0;
        int edgeContactPixels = 0;
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                byte current = tempCanvas[y, x];
                if (current == 0) continue;
                if (y + 1 < h && tempCanvas[y + 1, x] == current) score += 2.0;
                if (x + 1 < w && tempCanvas[y, x + 1] == current) score += 1.0;
                if (y == 0 || y == h - 1) edgeContactPixels++;
                if (x == 0 || x == w - 1) edgeContactPixels++;
            }
        }
        score -= (edgeContactPixels * 5.0);
        return score;
    }

    // 生データを2次元配列に展開
    private static byte[,] CreateCanvas(byte[] rawData, int w, int h, int depth)
    {
        byte[,] canvas = new byte[h, w];
        int bitIndex = 0;
        int len = rawData.Length;
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int val = 0;
                if (depth == 2) { // 2bit color
                    int byteIdx = bitIndex / 4;
                    int bitShift = 6 - ((bitIndex % 4) * 2);
                    if (byteIdx < len) val = (rawData[byteIdx] >> bitShift) & 0x03;
                } else { // 1bit color
                    int byteIdx = bitIndex / 8;
                    int bitShift = 7 - (bitIndex % 8);
                    if (byteIdx < len) {
                        int bit = (rawData[byteIdx] >> bitShift) & 0x01;
                        val = (bit == 1) ? 3 : 0;
                    }
                }
                canvas[y, x] = (byte)val;
                bitIndex++;
            }
        }
        return canvas;
    }

    // Amatsukaze独自のMD5計算処理
    // ファイルそのもののハッシュではなく、ピクセルデータを特定の順序でパックした
    // バイナリデータのMD5値をファイル名にする必要があります。
    private static string CalculateAmatsukazeMD5(byte[,] canvas)
    {
        int h = canvas.GetLength(0);
        int w = canvas.GetLength(1);
        int packedSize = (w * h + 3) / 4; 
        byte[] bData = new byte[packedSize]; 
        
        // 下の行から上の行へ、左から右へスキャンしてパックする
        for (int y = h - 1; y >= 0; y--) {
            for (int x = 0; x < w; x++) {
                int nPix = canvas[y, x];
                int nPos = y * w + x;
                int shift = (3 - (nPos % 4)) * 2;
                bData[nPos / 4] |= (byte)(nPix << shift);
            }
        }
        using (MD5 md5 = MD5.Create()) {
            byte[] hashBytes = md5.ComputeHash(bData, 0, packedSize);
            return BitConverter.ToString(hashBytes).Replace("-", "").ToUpper();
        }
    }

    // Amatsukaze用 BMP生成処理 (4bit RLE/Uncompressed)
    private static byte[] CreateAmatsukazeBMP(byte[,] canvas)
    {
        int h = canvas.GetLength(0);
        int w = canvas.GetLength(1);
        // Stride (1行あたりのバイト数) は4バイト境界に合わせる必要がある
        int stride = ((w * 4 + 31) / 32) * 4;
        int pixelDataSize = stride * h;
        // Header sizes: FileHeader(14) + InfoHeader(40) + Palette(4*16=64)
        int fileSize = 14 + 40 + 64 + pixelDataSize;

        using (var ms = new MemoryStream(fileSize))
        using (var writer = new BinaryWriter(ms)) {
            // Bitmap File Header
            writer.Write((ushort)0x4D42);   // "BM"
            writer.Write((uint)fileSize);
            writer.Write((ushort)0);
            writer.Write((ushort)0);
            writer.Write((uint)(14 + 40 + 64)); // Offset to pixel data

            // Bitmap Info Header
            writer.Write((uint)40);         // Header size
            writer.Write((int)w);           // Width
            writer.Write((int)h);           // Height
            writer.Write((ushort)1);        // Planes
            writer.Write((ushort)4);        // BitCount (4bit)
            writer.Write((uint)0);          // Compression (BI_RGB)
            writer.Write((uint)pixelDataSize);
            writer.Write((int)0);           // XPixelsPerMeter
            writer.Write((int)0);           // YPixelsPerMeter
            writer.Write((uint)0);          // ColorsUsed
            writer.Write((uint)0);          // ColorsImportant

            // Palette Write
            writer.Write(PALETTE);

            // Pixel Data Write (Bottom-up format)
            byte[] buffer = new byte[pixelDataSize];
            for (int y = 0; y < h; y++) {
                int srcY = (h - 1) - y; // BMPは上下逆(ボトムアップ)に格納される
                int rowOffset = y * stride;
                for (int x = 0; x < w; x+=2) {
                    byte p1 = canvas[srcY, x];
                    byte p2 = (x + 1 < w) ? canvas[srcY, x + 1] : (byte)0;
                    // 4bit x 2pixels = 1byte にパック
                    buffer[rowOffset + (x / 2)] = (byte)((p1 << 4) | (p2 & 0x0F));
                }
            }
            writer.Write(buffer);
            return ms.ToArray();
        }
    }
}
'@

# ---------------------------------------------------------
# PowerShell 関数定義
# ---------------------------------------------------------

function Initialize-Environment {
    # C#コードをコンパイルしてロード
    try { Add-Type -TypeDefinition $CSHARP_CODE -Language CSharp } catch { if (-not $_.Exception.Message.Contains("AmatsukazeLogic")) { throw "C# Compilation Failed: $($_.Exception.Message)" } }
    
    # ログファイルパスの生成 (スクリプトと同名の .log)
    $scriptName = if ($PSCommandPath) { [System.IO.Path]::GetFileName($PSCommandPath) } else { "Convert-DrcsJsonToAmatsukaze.ps1" }
    return [System.IO.Path]::ChangeExtension($scriptName, ".log")
}

function Get-JsonData {
    param([string]$Path)
    # HTTPS通信のためのTLS設定
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Write-Host "Loading JSON Data: $Path"
    
    if ($Path -match "^https?://") { 
        try { 
            # WebClient で UTF-8 を明示して取得。PowerShell (5.1) 対策
            $wc = New-Object System.Net.WebClient
            $wc.Encoding = [System.Text.Encoding]::UTF8
            $jsonStr = $wc.DownloadString($Path)
            return $jsonStr | ConvertFrom-Json
        } catch { 
            throw "Download Failed: $($_.Exception.Message)" 
        } 
    }
    elseif (Test-Path $Path) { 
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json 
    }
    else { 
        throw "File Not Found: $Path" 
    }
}

function Load-ExistingMap {
    param([string]$Path)
    $map = @{}; $lines = [System.Collections.Generic.List[string]]::new()
    # 既存のマップ定義ファイルが存在する場合、重複処理をスキップするために読み込む
    if (-not [string]::IsNullOrEmpty($Path) -and (Test-Path $Path)) {
        Write-Host "Loading Existing Map: $Path"
        $rawLines = Get-Content -LiteralPath $Path -Encoding UTF8
        if ($rawLines) { 
            $lines.AddRange([string[]]$rawLines); 
            foreach ($line in $rawLines) { 
                if ($line -match "^([0-9A-Fa-f]{32})=(.+)$") { 
                    $hash = $matches[1].ToUpper(); 
                    if (-not $map.ContainsKey($hash)) { $map[$hash] = $matches[2] } 
                } 
            } 
        }
        Write-Host "Existing Entries: $($map.Count)"
    }
    return @{ Map = $map; Lines = $lines }
}

function Process-Conversion {
    param($JsonData, $ExistingMapData, $OutputDir, $LogPath, [switch]$IncludeNonHD)
    $total = $JsonData.map.Count; $current = 0; $added = 0; $skipped = 0; $excludedNonHD = 0
    $logBuffer = @()
    $finalLines = [System.Collections.Generic.List[string]]::new()
    
    # 既存のマップ定義の内容を引き継ぐ
    if ($ExistingMapData.Lines -and $ExistingMapData.Lines.Count -gt 0) { $finalLines.AddRange($ExistingMapData.Lines) }
    $currentMap = $ExistingMapData.Map
    
    Write-Host "Starting Conversion ($total items)..."
    if ($IncludeNonHD) {
        Write-Host "  -> Mode: All Sizes (Including SD/OneSeg)" -ForegroundColor Yellow
    } else {
        Write-Host "  -> Mode: HD Only (36x36). Others are skipped." -ForegroundColor Cyan
    }

    foreach ($item in $JsonData.map) {
        $current++
        # 進捗表示 (500件ごと)
        if ($current % 500 -eq 0) { Write-Progress -Activity "Processing" -Status "$current / $total" -PercentComplete (($current / $total) * 100); Flush-LogBuffer -Path $LogPath -Buffer ([ref]$logBuffer) }
        
        # 必要なデータがない場合はスキップ
        if (-not $item.drcs -or -not $item.alternative) { continue }

        # C#ロジックで画像変換・MD5計算を実行
        $result = [AmatsukazeLogic]::Process($item.drcs)

        if ($result.Success) {
            # --- サイズフィルタ ---
            # IncludeNonHDがOFFの場合、36x36以外を除外 (HD画質のTSエンコード用)
            if (-not $IncludeNonHD -and ($result.Width -ne 36 -or $result.Height -ne 36)) {
                $excludedNonHD++
                continue
            }

            $hash = $result.Hash
            $char = $item.alternative
            
            # 自動判定(Auto-Detect)が行われた場合のみコンソールに詳細表示
            if ($result.DetectInfo -match "Auto-Detect") {
                 $logBuffer += "$hash=$char [$($result.DetectInfo)]"
                 Write-Host "  > $hash : $($result.DetectInfo)" -ForegroundColor Cyan
            }

            $logBuffer += "$hash=$char [BASE64: $($item.drcs)]"

            # 既にマップに存在する場合はファイル生成をスキップ
            if ($currentMap.ContainsKey($hash)) {
                $skipped++
            } else {
                # 新規登録: マップに追加し、BMPファイルを保存
                $finalLines.Add("$hash=$char")
                $currentMap[$hash] = $char
                $bmpPath = Join-Path $OutputDir "$hash.bmp"
                [System.IO.File]::WriteAllBytes($bmpPath, $result.BmpBytes)
                $added++
            }
        }
    }
    # 残りのログを出力
    Flush-LogBuffer -Path $LogPath -Buffer ([ref]$logBuffer)
    Write-Progress -Completed -Activity "Done"
    return @{ Lines = $finalLines; Added = $added; Skipped = $skipped; ExcludedNonHD = $excludedNonHD }
}

function Flush-LogBuffer { param($Path, [ref]$Buffer) if ($Buffer.Value.Count -gt 0) { Add-Content -Path $Path -Value $Buffer.Value -Encoding UTF8; $Buffer.Value = @() } }

# ---------------------------------------------------------
# Main 処理開始
# ---------------------------------------------------------
try {
    $logFilePath = Initialize-Environment
    if (Test-Path $logFilePath) { Clear-Content $logFilePath }
    
    # --- 安全機構: 出力先フォルダのチェック ---
    Write-Host "Output Directory: $OutputDir"
    if (Test-Path $OutputDir) {
        Write-Error "エラー: 出力先フォルダ '$OutputDir' は既に存在します。"
        Write-Error "データの混在を防ぐため、存在しないフォルダパスを指定するか、既存フォルダを削除してから再実行してください。"
        exit 1
    }
    New-Item -ItemType Directory -Path $OutputDir | Out-Null

    # データ読み込み
    $jsonData = Get-JsonData -Path $JsonPath
    if (-not $jsonData -or -not $jsonData.map) { throw "Invalid JSON Data." }
    $existingData = Load-ExistingMap -Path $ExistingMapPath
    
    # 変換処理実行
    $result = Process-Conversion -JsonData $jsonData -ExistingMapData $existingData -OutputDir $OutputDir -LogPath $logFilePath -IncludeNonHD:$IncludeNonHD

    # マップ定義ファイルの書き出し
    $finalMapPath = Join-Path $OutputDir $OutputMapFileName
    [System.IO.File]::WriteAllLines($finalMapPath, $result.Lines, [System.Text.Encoding]::UTF8)

    # 完了報告
    Write-Host "`nCompleted!" -ForegroundColor Green
    Write-Host "Output Map : $finalMapPath"
    Write-Host "Log File   : $logFilePath"
    Write-Host "Status     : Added $($result.Added), Skipped $($result.Skipped), Excluded(Non-HD) $($result.ExcludedNonHD)"
} catch {
    Write-Error "Error: $_"
    exit 1
}


