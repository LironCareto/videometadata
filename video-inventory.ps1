# Load config from JSON (same folder as script)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptDir 'config.json'
if (-Not (Test-Path $configPath)) {
    Write-Host "❌ Missing configuration file: $configPath"
    exit 1
}

$config = Get-Content $configPath | ConvertFrom-Json

# Path to ffprobe and sqlite3 from config
$ffprobe = $config.FfprobePath
$sqlite3 = $config.Sqlite3Path

# Root folders to scan from config
$rootPaths = $config.paths

# Extensions to include from config
$videoExtensions = $config.extensions

# Optional debug output
$enableDebugLog = $true
if ($config.PSObject.Properties.Name -contains "EnableDebugLog") {
    $enableDebugLog = [bool]$config.EnableDebugLog
}

# Generate timestamp for this run (used only for logs)
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$startTime = Get-Date

# Output files
$outputCsv = "video_inventory.csv"
$databasePath = "video_inventory.sqlite"
$errorLog = "video_inventory_errors_$timestamp.txt"
$debugLog = "video_inventory_debug_$timestamp.txt"
$summaryLog = "video_inventory_summary_$timestamp.log"

Write-Host "⚙️ Script started"

# Ensure logs exist and start logs with timestamp
if ($enableDebugLog) {
    Set-Content -Path $debugLog -Value "=== Inventory Script Started at $startTime ===`n" -Encoding UTF8
}
Set-Content -Path $summaryLog -Value "=== Inventory Summary Log ($startTime) ===`n" -Encoding UTF8

$errorMessages = @()
$totalFiles = 0
$globalIndex = 0

# Initialize CSV file with headers at the beginning (only if not exists)
if (-not (Test-Path $outputCsv)) {
    "Path,Filename,Container,DurationMin,SizeMB,VideoCodec,AudioCodec,AudioLangs,Resolution,SAR,DAR" | Out-File -FilePath $outputCsv -Encoding UTF8
}

foreach ($rootPath in $rootPaths) {
    Write-Host "🔍 Scanning files in ${rootPath}..."
    $allDiscovered = Get-ChildItem -Path $rootPath -Recurse -File -ErrorAction SilentlyContinue
    Write-Host ("📦 Total files found in {0}: {1}" -f $rootPath, $allDiscovered.Count)
    $matching = $allDiscovered | Where-Object {
        $ext = $_.Extension.ToLower()
        $videoExtensions -contains $ext
    }

    $totalFiles += $matching.Count
    $i = 0

    foreach ($file in $matching) {
        $i++
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
                Add-Content -Path $debugLog -Value "----- BEGIN: $($file.FullName) -----`n$jsonRaw`n----- END -----`n"
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
            Add-Content -Path $summaryLog -Value $summaryRow

            $record | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Add-Content -Path $outputCsv -Encoding UTF8
        }
        catch {
            $msg = "$($file.FullName) - ERROR: $($_.Exception.Message)"
            $errorMessages += $msg
        }
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

Write-Host "✅ Inventory saved to: $outputCsv"
Write-Host "📦 SQLite DB saved to: $databasePath"

if ($errorMessages.Count -gt 0) {
    $errorMessages | Set-Content -Path $errorLog -Encoding UTF8
    Write-Host "❗ Errors encountered. See $errorLog"
} else {
    Write-Host "✅ No errors encountered."
}

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

Write-Host "`n✅ Done!"
Write-Host "Summary log saved to: $summaryLog"
Write-Progress -Activity "Probing video files..." -Completed
Write-Host ""
