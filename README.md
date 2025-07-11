# Video Metadata Inventory Tool

This PowerShell script recursively scans folders for video files, extracts their metadata using `ffprobe`, and saves the results to a CSV file and an SQLite database. It is designed to handle large video collections and generate summary and debug logs for later inspection.

## Features

* Scans one or more folders recursively for video files
* Supports multiple video formats (`.mp4`, `.mkv`, `.avi`, etc.)
* Extracts metadata using `ffprobe`
* Saves inventory to:

  * CSV file
  * SQLite database
* Logs errors and warnings separately
* Optional debug mode with full raw JSON output per file
* Summary log with per-file entries and total elapsed time

## Requirements

* PowerShell 5.1 or later
* `ffprobe` (part of [FFmpeg](https://ffmpeg.org/))
* `sqlite3` command-line tool

## Setup

1. **Clone the repository**:

   ```bash
   git clone https://gitlab.com/your-repo-name/videometadata.git
   cd videometadata
   ```

2. **Configure `config.json`**:

   * Rename `config.json_sample` to `config.json`.
   * Edit the paths and settings according to your environment.

   ```json
   {
     "paths": ["D:\\My Videos"],
     "extensions": [".mp4", ".mkv", ".avi"],
     "OutputCsv": "video_inventory.csv",
     "ErrorLog": "video_inventory_errors.txt",
     "DebugLog": "video_inventory_debug.txt",
     "DatabasePath": "video_inventory.sqlite",
     "FfprobePath": "ffprobe",
     "Sqlite3Path": "sqlite3.exe",
     "EnableDebugLog": true
   }
   ```

3. **Run the script**:

   ```powershell
   ./video-inventory.ps1
   ```

## Output

* `video_inventory.csv`: CSV with extracted metadata
* `video_inventory.sqlite`: SQLite DB with the same data
* `video_inventory_summary_<timestamp>.log`: Log with one line per processed file + summary
* `video_inventory_debug_<timestamp>.txt`: Raw JSON for each file (if `EnableDebugLog` is `true`)
* `video_inventory_errors_<timestamp>.txt`: Only generated if there are errors

## Ignored Files (via `.gitignore`)

To avoid committing private data, the following are ignored:

* `config.json` (use `config.json_sample` for templates)
* `*.sqlite`
* `*.csv`
* `*.log`
* `*.txt`

## License

MIT License

---

*This tool was developed for personal archival purposes, but feel free to fork and adapt it to your needs.*
