# Load config from JSON (same folder as script)
$scriptPath = $MyInvocation.MyCommand.Path
if (-not $scriptPath) {
    Write-Host "❌ Cannot determine script path. Running in a restricted context?"
    exit 1
}
$scriptDir = Split-Path -Parent $scriptPath
try {
    Set-Location $scriptDir -ErrorAction Stop
} catch {
    Write-Host "❌ Failed to set working directory to $scriptDir"
    exit 1
}

$configPath = Join-Path $scriptDir 'config.json'
if (-Not (Test-Path $configPath)) {
    Write-Host "❌ Missing configuration file: $configPath"
    exit 1
}

$config = Get-Content $configPath | ConvertFrom-Json

$ffprobe = $config.FfprobePath
$sqlite3 = $config.Sqlite3Path
$rootPaths = $config.paths
$videoExtensions = $config.extensions

$enableDebugLog = $true
if ($config.PSObject.Properties.Name -contains "EnableDebugLog") {
    $enableDebugLog = [bool]$config.EnableDebugLog
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$startTime = Get-Date

$outputCsvFinal = "video_inventory.csv"
$outputCsv = "$outputCsvFinal.tmp"
$databasePath = "video_inventory.sqlite"
$errorLogFinal = "video_inventory_errors_$timestamp.txt"
$errorLog = "$errorLogFinal.tmp"
$debugLog = "video_inventory_debug_$timestamp.txt"
$summaryLogFinal = "video_inventory_summary_$timestamp.log"
$summaryLog = "$summaryLogFinal.tmp"

Write-Host "⚙️ Script started"

if ($enableDebugLog) {
    Set-Content -Path $debugLog -Value "=== Inventory Script Started at $startTime ===`n" -Encoding UTF8
}
Set-Content -Path $summaryLog -Value "=== Inventory Summary Log ($startTime) ===`n" -Encoding UTF8

$errorMessages = @()
$globalIndex = 0

if (-not (Test-Path $outputCsv)) {
    "Path,Filename,Container,DurationMin,SizeMB,VideoCodec,AudioCodec,AudioLangs,Resolution,SAR,DAR" | Out-File -FilePath $outputCsv -Encoding UTF8
}

# Preload all video files to compute accurate ETA
$allFiles = @()
foreach ($rootPath in $rootPaths) {
    Write-Host "🔍 Scanning files in ${rootPath}..."
    $found = Get-ChildItem -Path $rootPath -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $videoExtensions -contains $_.Extension.ToLower()
    }
    Write-Host ("📦 Total files found in {0}: {1}" -f $rootPath, $found.Count)
    $allFiles += $found
}

$totalFiles = $allFiles.Count

foreach ($file in $allFiles) {
    $globalIndex++
    $elapsed = (Get-Date) - $startTime
    $avgPerFile = if ($globalIndex -gt 0) { $elapsed.TotalSeconds / $globalIndex } else { 0 }
    $remainingSeconds = ($totalFiles - $globalIndex) * $avgPerFile
    $eta = (Get-Date).AddSeconds($remainingSeconds)

    Write-Progress -Activity "Probing video files..." `
        -Status "$globalIndex of $totalFiles | Elapsed: $([math]::Round($elapsed.TotalMinutes,1)) min | ETA: $($eta.ToString("HH:mm"))" `
        -PercentComplete (($globalIndex / $totalFiles) * 100)

    $tempJsonPath = [System.IO.Path]::GetTempFileName()
    $tempErrPath = [System.IO.Path]::GetTempFileName()

    try {
        Start-Process -FilePath $ffprobe `
            -ArgumentList @(
                "-v", "error",
                "-show_format",
                "-show_streams",
                "-print_format", "json",
                "-i", "`"$($file.FullName)`""
            ) `
            -NoNewWindow `
            -RedirectStandardOutput $tempJsonPath `
            -RedirectStandardError $tempErrPath `
            -Wait

        $jsonRaw = Get-Content $tempJsonPath -Raw -ErrorAction SilentlyContinue
        $stderrOutput = Get-Content $tempErrPath -Raw -ErrorAction SilentlyContinue
        Remove-Item $tempJsonPath, $tempErrPath -Force -ErrorAction SilentlyContinue

        if ($stderrOutput -and $stderrOutput.Trim().Length -gt 0) {
            $msg = "$($file.FullName) - WARNING: $stderrOutput"
            $errorMessages += $msg
        }

        if ($enableDebugLog) {
            [System.IO.File]::AppendAllText($debugLog, "----- BEGIN: $($file.FullName) -----`n$jsonRaw`n----- END -----`n")
        }

        if (-not $jsonRaw -or $jsonRaw -notmatch '{') {
            $msg = "$($file.FullName) - SKIPPED: No JSON output from ffprobe"
            $errorMessages += $msg
            continue
        }

        $json = $jsonRaw | ConvertFrom-Json -ErrorAction Stop
        $format = $json.format
        $video = $json.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
        $audios = $json.streams | Where-Object { $_.codec_type -eq "audio" }

        if (-not $format -or -not $video) {
            $msg = "$($file.FullName) - SKIPPED: Missing format or video stream info"
            $errorMessages += $msg
            continue
        }

        $audioLangs = ($audios | ForEach-Object { $_.tags.language }) -join ";"
        $audioCodecs = ($audios | ForEach-Object { $_.codec_name }) -join ";"

        $record = [PSCustomObject]@{
            Path         = $file.DirectoryName
            Filename     = $file.Name
            Container    = $format.format_name
            DurationMin  = [math]::Round([double]$format.duration / 60, 2)
            SizeMB       = [math]::Round([double]$format.size / 1MB, 2)
            VideoCodec   = $video.codec_name
            AudioCodec   = $audioCodecs
            AudioLangs   = $audioLangs
            Resolution   = if ($video) { "$($video.width)x$($video.height)" } else { "" }
            SAR          = $video.sample_aspect_ratio
            DAR          = $video.display_aspect_ratio
        }

        $summaryRow = "[$globalIndex/$totalFiles] $($record.Filename) | $($record.DurationMin) min | $($record.VideoCodec) | [$($record.AudioLangs)]"
        try {
            Add-Content -Path $summaryLog -Value "$summaryRow"
        } catch {
            $msg = "$($file.FullName) - ERROR writing to summary log: $($_.Exception.Message)"
            $errorMessages += $msg
        }

        $csvLine = $record | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1
        try {
            Add-Content -Path $outputCsv -Value ($csvLine -join "`n")
        } catch {
            $msg = "$($file.FullName) - ERROR writing to CSV: $($_.Exception.Message)"
            $errorMessages += $msg
        }
    }
    catch {
        $msg = "$($file.FullName) - ERROR: $($_.Exception.Message)"
        $errorMessages += $msg
    }
}

Write-Host "📦 SQLite DB will be saved to: $databasePath"
if (Test-Path $databasePath) { Remove-Item $databasePath -Force }

$schema = @"
CREATE TABLE inventory (
    Path TEXT,
    Filename TEXT,
    Container TEXT,
    DurationMin REAL,
    SizeMB REAL,
    VideoCodec TEXT,
    AudioCodec TEXT,
    AudioLangs TEXT,
    Resolution TEXT,
    SAR TEXT,
    DAR TEXT
);
"@
$schema | & $sqlite3 $databasePath

$tempCsv = "temp_import.csv"
Import-Csv -Path $outputCsv | Export-Csv -Path $tempCsv -NoTypeInformation -Encoding UTF8

$importSql = @"
.mode csv
.separator ","
.import --skip 1 "$tempCsv" inventory
.quit
"@
$importSql | Set-Content -Path temp_import.sql -Encoding UTF8
& cmd.exe /c "$sqlite3 $databasePath < temp_import.sql"
Remove-Item temp_import.sql, $tempCsv -Force -ErrorAction SilentlyContinue

# Add estimated size with H.265 (assumes 50% compression rate)
$addColumnSql = @"
ALTER TABLE inventory ADD COLUMN EstSizeH265MB REAL;
UPDATE inventory SET EstSizeH265MB = ROUND(SizeMB * 
    CASE
        WHEN LOWER(VideoCodec) = 'mpeg2video' THEN 0.3
        WHEN LOWER(VideoCodec) = 'mpeg4' THEN 0.45
        WHEN LOWER(VideoCodec) = 'h264' THEN 0.65
        WHEN LOWER(VideoCodec) = 'vp8' THEN 0.6
        WHEN LOWER(VideoCodec) = 'hevc' THEN 1.0
        WHEN LOWER(VideoCodec) = 'wmv3' THEN 0.4
        WHEN LOWER(VideoCodec) = 'divx' THEN 0.4
        WHEN LOWER(VideoCodec) = 'h263' THEN 0.3
        ELSE 0.5
    END
, 2);
.quit
"@
$addColumnSql | Set-Content -Path temp_postprocess.sql -Encoding UTF8
& cmd.exe /c "$sqlite3 $databasePath < temp_postprocess.sql"
Remove-Item temp_postprocess.sql -Force -ErrorAction SilentlyContinue


$endTime = Get-Date
$duration = $endTime - $startTime
if ($enableDebugLog) {
    Add-Content -Path $debugLog -Value "`n=== Script finished at $endTime ==="
    Add-Content -Path $debugLog -Value "Total runtime: $($duration.ToString())"
    Add-Content -Path $debugLog -Value "Errors: $($errorMessages.Count)"
}
Add-Content -Path $summaryLog -Value "`n=== Summary Complete ==="
Add-Content -Path $summaryLog -Value "Errors: $($errorMessages.Count)"
Add-Content -Path $summaryLog -Value "Elapsed time: $($duration.ToString())"
Add-Content -Path $summaryLog -Value "Started: $startTime"
Add-Content -Path $summaryLog -Value "Ended: $endTime"

Move-Item -Force -Path $outputCsv -Destination $outputCsvFinal
Move-Item -Force -Path $summaryLog -Destination $summaryLogFinal
if ($errorMessages.Count -gt 0) {
    $errorMessages | Set-Content -Path $errorLog -Encoding UTF8
    Move-Item -Force -Path $errorLog -Destination $errorLogFinal
    Write-Host "❗ Errors encountered. See $errorLogFinal"
} else {
    Write-Host "✅ No errors encountered."
}

Write-Host "✅ Inventory saved to: $outputCsvFinal"
Write-Host "📦 SQLite DB saved to: $databasePath"
Write-Host "`n✅ Done!"
Write-Host "Summary log saved to: $summaryLogFinal"
Write-Progress -Activity "Probing video files..." -Completed
Write-Host ""
