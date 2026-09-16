<#
.SYNOPSIS
  Import a fetched database dump into a Local site and fix up URLs.

  Run this from that site's own Local "Open Site Shell" window (right-click
  the site in Local -> Open Site Shell). That's the only place `wp` is wired
  up to the site's own local database - running it from anywhere else will
  either fail outright or hit the wrong database.

  Companion to sync-site-to-local.sh's 'fetch' stage, which still runs in
  WSL. fetch prints the exact command to run here, dump path included.

.PARAMETER Dump
  Path to the db.sql or db.sql.gz produced by 'fetch'. A WSL path needs its
  UNC form, e.g. \\wsl.localhost\Ubuntu\home\christian\site-syncs\...\db.sql.gz
  (check your distro name with 'wsl -l -v' if you're not sure it's Ubuntu).

.PARAMETER LiveUrl
  The live site's URL, e.g. https://folkquiz.com

.PARAMETER LocalUrl
  The Local site's URL, e.g. http://folkquiz.local

.PARAMETER SkipWpConfig
  Skip adding the local-only wp-config overrides.

.PARAMETER SkipSearchReplace
  Skip rewriting URLs in the database.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install-to-local.ps1 `
    -Dump "\\wsl.localhost\Ubuntu\home\christian\site-syncs\jolt-folkquiz\20260916-205135\db.sql.gz" `
    -LiveUrl "https://folkquiz.com" `
    -LocalUrl "http://folkquiz.local"
#>
param(
    [Parameter(Mandatory = $true)][string]$Dump,
    [Parameter(Mandatory = $true)][string]$LiveUrl,
    [Parameter(Mandatory = $true)][string]$LocalUrl,
    [switch]$SkipWpConfig,
    [switch]$SkipSearchReplace
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

if (-not (Test-Path -LiteralPath $Dump)) {
    Write-Error "No such file: $Dump"
    exit 1
}

# wp db import can't read .gz directly - decompress alongside it first if needed.
$sqlPath = $Dump
if ($Dump.ToLower().EndsWith(".gz")) {
    $sqlPath = $Dump.Substring(0, $Dump.Length - 3)
    Write-Host "==> Decompressing $Dump"
    $inStream    = [System.IO.File]::OpenRead($Dump)
    $outStream   = [System.IO.File]::Create($sqlPath)
    $gzipStream  = New-Object System.IO.Compression.GZipStream($inStream, [System.IO.Compression.CompressionMode]::Decompress)
    $gzipStream.CopyTo($outStream)
    $gzipStream.Close(); $outStream.Close(); $inStream.Close()
}

Write-Host "==> Importing database"
wp db import "$sqlPath"
if ($LASTEXITCODE -ne 0) { Write-Error "wp db import failed"; exit 1 }

if (-not $SkipSearchReplace) {
    Write-Host "==> Rewriting URLs ($LiveUrl -> $LocalUrl)"
    wp search-replace "$LiveUrl" "$LocalUrl" --all-tables --skip-columns=guid
}

if (-not $SkipWpConfig) {
    Write-Host "==> Local-only wp-config tweaks"
    $marker = "local overrides (added by sync script)"
    $wpConfigPath = "wp-config.php"

    if (-not (Test-Path -LiteralPath $wpConfigPath)) {
        Write-Host "    wp-config.php not found in current directory, skipping"
    } else {
        $content = Get-Content -LiteralPath $wpConfigPath -Raw
        if ($content -notmatch [regex]::Escape($marker)) {
            $extra = "`n// $marker`ndefine('WP_ENVIRONMENT_TYPE', 'local');`ndefine('DISABLE_WP_CRON', true);`n`n"
            $pattern = '(?s)(/\*\s*That.s all, stop editing.*)'
            $replacement = $extra + '$1'
            $newContent = $content -replace $pattern, $replacement
            if ($newContent -eq $content) {
                Write-Host "    couldn't find the usual wp-config marker comment, leaving wp-config.php alone"
            } else {
                Set-Content -LiteralPath $wpConfigPath -Value $newContent -NoNewline
                Write-Host "    added WP_ENVIRONMENT_TYPE + DISABLE_WP_CRON to wp-config.php"
            }
        } else {
            Write-Host "    already present, skipping"
        }
    }
}

Write-Host "==> Flushing cache"
wp cache flush

Write-Host ""
Write-Host "Done. Site should now be live at $LocalUrl"