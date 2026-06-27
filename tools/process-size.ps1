# tools/process-size.ps1
if ($args -ne 0) {
    exit $args
}

# 1. Locate the compiled binary artifact
$binFiles = Get-Item "build/*.bin" -ErrorAction SilentlyContinue
if (-not $binFiles) {
    Write-Warning "No binary files found in the build directory."
    exit 0
}
$bin = $binFiles
$size = $bin.Length

# 2. Parse the partition table using the active ESP-IDF Python tool
$binPartTable = "build/partition_table/partition-table.bin"
$part = 0x100000 # Safety default fallback value (1MB)

if (Test-Path $binPartTable) {
    # Fetch the CSV structure and filter out python output header noise
    $partCsv = python "$env:IDF_PATH/components/partition_table/gen_esp32part.py" $binPartTable
    $partLine = $partCsv | Where-Object { $_ -match '^[^#].*,\s*app\s*,' } | Select-Object -First 1
    
    if ($partLine) {
        # Split line fields by comma and extract the 5th element (Size)
        $fields = ($partLine -split ',').Trim()
        if ($fields.Count -ge 5) {
            $partSizeHex = $fields[4]
            try {
                $part = [Convert]::ToInt32($partSizeHex, 16)
            } catch {
                $part = 0x100000
            }
        }
    }
}

# 3. Calculate metrics safely
if ($part -le 0) { $part = 0x100000 }
$free = $part - $size
$pct = [Math]::Round(($free / $part) * 100, 1)

# 4. Output the readable decimal structure cleanly
Write-Output "`n[DECIMAL SIZE SUMMARY]"
Write-Output ("{0} binary size {1:N0} bytes." -f $bin.Name, $size)
Write-Output ("Smallest app partition is {0:N0} bytes." -f $part)
Write-Output ("{0:N0} bytes ({1}%) free.`n" -f $free, $pct)

exit 0
