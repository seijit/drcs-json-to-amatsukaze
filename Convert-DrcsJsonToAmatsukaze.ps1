<#
.SYNOPSIS
    drcs-subst.json を Amatsukaze 互換の BMP と drcs_map.txt に変換・マージします。
    v30: 可変サイズ出力対応版。36x36への強制リサイズを廃止し、本来のサイズとハッシュ値を出力します。
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)] [string]$ExistingMapPath = $null,
    [Parameter(Position=1)] [string]$JsonPath = "https://archive.hsk.st.nhk/npd3/config/drcs-subst.json",
    [Parameter(Position=2)] [string]$OutputDir = "drcs_output",
    [Parameter(Position=3)] [string]$OutputMapFileName = "drcs_map.txt"
)

# 定数定義: C#ロジック (可変サイズ対応版)
Set-Variable -Name CSHARP_CODE -Option Constant -Value @'
using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Collections.Generic;

public class AmatsukazeLogic
{
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

            byte[] rawData = Convert.FromBase64String(base64String);
            
            // サイズ推定
            int w, h, depth;
            EstimateFormatWithAnalysis(rawData, out w, out h, out depth);
            
            if (rawData.Length == 72) {
                res.DetectInfo = String.Format("Auto-Detect 72bytes -> {0}x{1}", w, h);
            } else {
                res.DetectInfo = String.Format("{0} bytes -> {1}x{2} ({3}bit)", rawData.Length, w, h, depth == 2 ? 2 : 1);
            }

            // 指定されたサイズ(w, h)そのままでキャンバスを作成（センタリング・36x36強制を廃止）
            byte[,] canvas = CreateCanvas(rawData, w, h, depth);
            
            // そのキャンバスサイズに基づいてハッシュ計算
            res.Hash = CalculateAmatsukazeMD5(canvas);
            
            // そのキャンバスサイズに基づいてBMP生成
            res.BmpBytes = CreateAmatsukazeBMP(canvas);
            
            res.Success = true;

        } catch (Exception ex) {
            res.ErrorMessage = ex.Message;
        }
        return res;
    }

    private static void EstimateFormatWithAnalysis(byte[] rawData, out int w, out int h, out int depth)
    {
        int len = rawData.Length;
        w = 36; h = 36; depth = 2; // Default fallback

        // 明確なサイズ
        if (len == 324) { w = 36; h = 36; depth = 2; return; }
        if (len == 162) { w = 18; h = 36; depth = 2; return; }
        if (len == 225) { w = 30; h = 30; depth = 2; return; }
        if (len == 113) { w = 30; h = 30; depth = 1; return; }
        if (len == 96)  { w = 16; h = 24; depth = 2; return; }
        if (len == 57)  { w = 15; h = 30; depth = 1; return; }

        // 72バイト問題対策
        if (len == 72) {
            double scoreA = AnalyzePattern(rawData, 16, 18, 2);
            double scoreB = AnalyzePattern(rawData, 12, 24, 2);
            
            if (scoreB >= scoreA * 0.8) {
                w = 12; h = 24; depth = 2;
            } else {
                w = 16; h = 18; depth = 2;
            }
            return;
        }

        // その他汎用探索
        int[] commonHeights = new int[] { 36, 30, 24, 18, 20, 16 };
        int[] tryDepths = new int[] { 2, 1 };

        foreach (int d in tryDepths) {
            foreach (int tryH in commonHeights) {
                int tryW = (len * 8) / (tryH * d);
                if (tryW > 0) {
                    int calcLen = (tryW * tryH * d + 7) / 8;
                    if (calcLen == len) {
                        w = tryW; h = tryH; depth = d; return;
                    }
                }
            }
        }
        
        // Fallback
        if ((len * 4) % 36 == 0) {
            h = 36; w = (len * 4) / 36;
        } else {
             h = 36; w = (len * 4) / 36; if (w == 0) w = 1;
        }
    }

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

    private static byte[,] CreateCanvas(byte[] rawData, int w, int h, int depth)
    {
        byte[,] canvas = new byte[h, w]; // h行 w列
        int bitIndex = 0;
        int len = rawData.Length;

        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int val = 0;
                if (depth == 2) {
                    int byteIdx = bitIndex / 4;
                    int bitShift = 6 - ((bitIndex % 4) * 2);
                    if (byteIdx < len) val = (rawData[byteIdx] >> bitShift) & 0x03;
                } else {
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

    private static string CalculateAmatsukazeMD5(byte[,] canvas)
    {
        int h = canvas.GetLength(0);
        int w = canvas.GetLength(1);
        
        int packedSize = (w * h + 3) / 4; 
        byte[] bData = new byte[packedSize]; 
        
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

    private static byte[] CreateAmatsukazeBMP(byte[,] canvas)
    {
        int h = canvas.GetLength(0);
        int w = canvas.GetLength(1);

        // BMP Stride計算: ((width * 4bit + 31) / 32) * 4 bytes
        int stride = ((w * 4 + 31) / 32) * 4;
        
        int pixelDataSize = stride * h;
        int fileSize = 14 + 40 + 64 + pixelDataSize;

        using (var ms = new MemoryStream(fileSize))
        using (var writer = new BinaryWriter(ms)) {
            // Bitmap File Header
            writer.Write((ushort)0x4D42);
            writer.Write((uint)fileSize);
            writer.Write((ushort)0);
            writer.Write((ushort)0);
            writer.Write((uint)(14 + 40 + 64));

            // Bitmap Info Header
            writer.Write((uint)40);
            writer.Write((int)w); // 可変幅
            writer.Write((int)h); // 可変高さ
            writer.Write((ushort)1);
            writer.Write((ushort)4);
            writer.Write((uint)0);
            writer.Write((uint)pixelDataSize);
            writer.Write((int)0);
            writer.Write((int)0);
            writer.Write((uint)0);
            writer.Write((uint)0);

            // Palette
            writer.Write(PALETTE);

            // Pixel Data
            byte[] buffer = new byte[pixelDataSize];
            for (int y = 0; y < h; y++) {
                int srcY = (h - 1) - y;
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
    try { Add-Type -TypeDefinition $CSHARP_CODE -Language CSharp } catch { if (-not $_.Exception.Message.Contains("AmatsukazeLogic")) { throw "C# Compilation Failed: $($_.Exception.Message)" } }
    $scriptName = if ($PSCommandPath) { [System.IO.Path]::GetFileName($PSCommandPath) } else { "Convert.ps1" }
    return [System.IO.Path]::ChangeExtension($scriptName, ".log")
}

function Get-JsonData {
    param([string]$Path)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Host "Loading JSON Data: $Path"
    if ($Path -match "^https?://") { try { return Invoke-RestMethod -Uri $Path -Method Get } catch { throw "Download Failed: $($_.Exception.Message)" } }
    elseif (Test-Path $Path) { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    else { throw "File Not Found: $Path" }
}

function Load-ExistingMap {
    param([string]$Path)
    $map = @{}; $lines = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrEmpty($Path) -and (Test-Path $Path)) {
        Write-Host "Loading Existing Map: $Path"
        $rawLines = Get-Content -LiteralPath $Path -Encoding UTF8
        if ($rawLines) { $lines.AddRange([string[]]$rawLines); foreach ($line in $rawLines) { if ($line -match "^([0-9A-Fa-f]{32})=(.+)$") { $hash = $matches[1].ToUpper(); if (-not $map.ContainsKey($hash)) { $map[$hash] = $matches[2] } } } }
        Write-Host "Existing Entries: $($map.Count)"
    }
    return @{ Map = $map; Lines = $lines }
}

function Process-Conversion {
    param($JsonData, $ExistingMapData, $OutputDir, $LogPath)
    $total = $JsonData.map.Count; $current = 0; $added = 0; $skipped = 0
    $logBuffer = @()
    $finalLines = [System.Collections.Generic.List[string]]::new()
    if ($ExistingMapData.Lines -and $ExistingMapData.Lines.Count -gt 0) { $finalLines.AddRange($ExistingMapData.Lines) }
    $currentMap = $ExistingMapData.Map
    
    Write-Host "Starting Conversion ($total items)..."

    foreach ($item in $JsonData.map) {
        $current++
        if ($current % 500 -eq 0) { Write-Progress -Activity "Processing" -Status "$current / $total" -PercentComplete (($current / $total) * 100); Flush-LogBuffer -Path $LogPath -Buffer ([ref]$logBuffer) }
        if (-not $item.drcs -or -not $item.alternative) { continue }

        $result = [AmatsukazeLogic]::Process($item.drcs)

        if ($result.Success) {
            $hash = $result.Hash
            $char = $item.alternative
            
            # 自動判定の結果をログに出力(72bytesのときのみ)
            if ($result.DetectInfo -match "Auto-Detect") {
                 $logBuffer += "$hash=$char [$($result.DetectInfo)]"
                 Write-Host "  > $hash : $($result.DetectInfo)" -ForegroundColor Cyan
            }

            $logBuffer += "$hash=$char [BASE64: $($item.drcs)]"

            if ($currentMap.ContainsKey($hash)) {
                $skipped++
            } else {
                $finalLines.Add("$hash=$char")
                $currentMap[$hash] = $char
                $bmpPath = Join-Path $OutputDir "$hash.bmp"
                [System.IO.File]::WriteAllBytes($bmpPath, $result.BmpBytes)
                $added++
            }
        }
    }
    Flush-LogBuffer -Path $LogPath -Buffer ([ref]$logBuffer)
    Write-Progress -Completed -Activity "Done"
    return @{ Lines = $finalLines; Added = $added; Skipped = $skipped }
}

function Flush-LogBuffer { param($Path, [ref]$Buffer) if ($Buffer.Value.Count -gt 0) { Add-Content -Path $Path -Value $Buffer.Value -Encoding UTF8; $Buffer.Value = @() } }

# --- Main ---
try {
    $logFilePath = Initialize-Environment
    if (Test-Path $logFilePath) { Clear-Content $logFilePath }
    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }
    
    $jsonData = Get-JsonData -Path $JsonPath
    if (-not $jsonData -or -not $jsonData.map) { throw "Invalid JSON Data." }
    $existingData = Load-ExistingMap -Path $ExistingMapPath
    
    $result = Process-Conversion -JsonData $jsonData -ExistingMapData $existingData -OutputDir $OutputDir -LogPath $logFilePath

    $finalMapPath = Join-Path $OutputDir $OutputMapFileName
    [System.IO.File]::WriteAllLines($finalMapPath, $result.Lines, [System.Text.Encoding]::UTF8)

    Write-Host "`nCompleted!" -ForegroundColor Green
    Write-Host "Output Map : $finalMapPath"
    Write-Host "Log File   : $logFilePath"
    Write-Host "Status     : Added $($result.Added), Skipped $($result.Skipped)"
} catch { Write-Error "Error: $_"; exit 1 }
