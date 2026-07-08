$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$PlaylistPath = Join-Path $Root "turktv.m3u"
$ReportCsv = Join-Path $Root "rapport_chaines.csv"
$BackupDir = Join-Path $Root "backups"

function Read-TextFile {
    param([string]$Path)
    return [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
}

function Write-TextFile {
    param(
        [string]$Path,
        [string[]]$Lines
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $Lines, $utf8NoBom)
}

function Get-M3UEntries {
    param([string[]]$Lines)

    $entries = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i].Trim()
        if (-not $line.StartsWith("#EXTINF", [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $urlLine = -1
        for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
            $candidate = $Lines[$j].Trim()
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            if ($candidate.StartsWith("#")) { continue }
            $urlLine = $j
            break
        }

        if ($urlLine -lt 0) { continue }

        $entries.Add([pscustomobject]@{
            Number = $entries.Count + 1
            InfoLine = $i
            UrlLine = $urlLine
            Lines = @($Lines[$i], $Lines[$urlLine])
        })
    }

    return $entries
}

if (-not (Test-Path -LiteralPath $PlaylistPath)) {
    throw "Fichier introuvable: $PlaylistPath"
}

if (-not (Test-Path -LiteralPath $ReportCsv)) {
    throw "Rapport introuvable: $ReportCsv. Lance d'abord la verification des chaines."
}

$report = @(Import-Csv -LiteralPath $ReportCsv)
if ($report.Count -eq 0) {
    throw "Le rapport est vide."
}

$okNumbers = New-Object System.Collections.Generic.HashSet[int]
foreach ($row in $report) {
    if ($row.Ok -eq "True") {
        [void]$okNumbers.Add([int]$row.Number)
    }
}

$lines = Read-TextFile $PlaylistPath
$entries = @(Get-M3UEntries $lines)

if ($entries.Count -eq 0) {
    throw "Aucune chaine trouvee dans turktv.m3u"
}

if (-not (Test-Path -LiteralPath $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir | Out-Null
}

$backupPath = Join-Path $BackupDir ("turktv_avant_nettoyage_{0}.m3u" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
Copy-Item -LiteralPath $PlaylistPath -Destination $backupPath -Force

$clean = New-Object System.Collections.Generic.List[string]
$clean.Add("#EXTM3U")
$clean.Add("# TURKTV - playlist nettoyee")
$clean.Add(("# Date de nettoyage: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")))
$clean.Add(("# Chaines conservees: {0}" -f $okNumbers.Count))
$clean.Add("")

foreach ($entry in $entries) {
    if ($okNumbers.Contains([int]$entry.Number)) {
        foreach ($line in $entry.Lines) {
            $clean.Add($line)
        }
    }
}

Write-TextFile -Path $PlaylistPath -Lines $clean

$removed = $entries.Count - $okNumbers.Count
Write-Host ("Playlist nettoyee: {0} chaines conservees, {1} supprimees." -f $okNumbers.Count, $removed) -ForegroundColor Green
Write-Host ("Sauvegarde complete: {0}" -f $backupPath)
Write-Host "Relance ensuite la publication GitHub pour que le boitier recupere la liste nettoyee."
