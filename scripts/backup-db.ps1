#Requires -Version 5.1
<#
.SYNOPSIS
  pg_dump backup for Neon Postgres (or any DATABASE_URL).

.DESCRIPTION
  Reads DATABASE_URL from the environment. Writes a timestamped .sql file locally.
  Install PostgreSQL client tools so pg_dump is on PATH, or set PGDUMP_PATH.

.EXAMPLE
  $env:DATABASE_URL = "postgresql://..."
  .\scripts\backup-db.ps1
#>

$ErrorActionPreference = "Stop"

if (-not $env:DATABASE_URL) {
    Write-Error "DATABASE_URL is not set. Export it in this session or in User environment variables."
}

$pgDump = $env:PGDUMP_PATH
if (-not $pgDump) {
    $pgDump = (Get-Command pg_dump -ErrorAction SilentlyContinue).Source
}
if (-not $pgDump) {
    Write-Error "pg_dump not found. Install PostgreSQL client tools or set PGDUMP_PATH."
}

$outDir = if ($env:PIXEL_CHAT_BACKUP_DIR) { $env:PIXEL_CHAT_BACKUP_DIR } else { "D:\pixel-chat\backups" }
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outFile = Join-Path $outDir "pixel_chat_$stamp.sql"

Write-Host "Backing up to $outFile ..."
& $pgDump $env:DATABASE_URL -F p -f $outFile
if ($LASTEXITCODE -ne 0) {
    Write-Error "pg_dump failed with exit code $LASTEXITCODE"
}

Write-Host "Backup completed: $outFile"
