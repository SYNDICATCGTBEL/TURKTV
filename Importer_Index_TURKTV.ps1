$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$PlaylistPath = Join-Path $Root "turktv.m3u"
$IndexPath = Join-Path $Root "index.m3u"
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

function Normalize-Name {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    $value = $Name.Trim().ToUpperInvariant()
    $value = $value -replace "\(BACKUP\)", "BACKUP"
    $value = $value -replace "\[.*?\]", ""
    $value = $value.Normalize([Text.NormalizationForm]::FormD)
    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $value.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($char)
        if ($category -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($char)
        }
    }
    $value = $builder.ToString()
    $value = $value -replace "İ", "I" -replace "ı", "I"
    $value = $value -replace "[^A-Z0-9]+", ""
    return $value
}

function Get-ChannelName {
    param([string]$Line)
    $commaIndex = $Line.LastIndexOf(",")
    if ($commaIndex -ge 0 -and $commaIndex -lt ($Line.Length - 1)) {
        return $Line.Substring($commaIndex + 1).Trim()
    }
    return ""
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

        $name = Get-ChannelName $Lines[$i]
        $url = $Lines[$urlLine].Trim()
        $entries.Add([pscustomobject]@{
            Name = $name
            Key = Normalize-Name $name
            Url = $url
            UrlKey = $url.ToLowerInvariant()
            Lines = @($Lines[$i].TrimEnd(), $url)
        })
    }

    return $entries
}

if (-not (Test-Path -LiteralPath $PlaylistPath)) {
    throw "Fichier introuvable: $PlaylistPath"
}
if (-not (Test-Path -LiteralPath $IndexPath)) {
    throw "Fichier introuvable: $IndexPath"
}

$playlistLines = Read-TextFile $PlaylistPath
$indexLines = Read-TextFile $IndexPath
$playlistEntries = @(Get-M3UEntries $playlistLines)
$indexEntries = @(Get-M3UEntries $indexLines)

if ($playlistEntries.Count -eq 0) { throw "Aucune chaine trouvee dans turktv.m3u" }
if ($indexEntries.Count -eq 0) { throw "Aucune chaine trouvee dans index.m3u" }

$knownNames = New-Object System.Collections.Generic.HashSet[string]
$knownUrls = New-Object System.Collections.Generic.HashSet[string]
foreach ($entry in $playlistEntries) {
    if (-not [string]::IsNullOrWhiteSpace($entry.Key)) { [void]$knownNames.Add($entry.Key) }
    if (-not [string]::IsNullOrWhiteSpace($entry.UrlKey)) { [void]$knownUrls.Add($entry.UrlKey) }
}

$toAdd = New-Object System.Collections.Generic.List[object]
foreach ($entry in $indexEntries) {
    if ([string]::IsNullOrWhiteSpace($entry.Key) -or [string]::IsNullOrWhiteSpace($entry.UrlKey)) {
        continue
    }
    if ($knownNames.Contains($entry.Key) -or $knownUrls.Contains($entry.UrlKey)) {
        continue
    }

    $toAdd.Add($entry)
    [void]$knownNames.Add($entry.Key)
    [void]$knownUrls.Add($entry.UrlKey)
}

if ($toAdd.Count -eq 0) {
    Write-Host "Aucune chaine absente trouvee dans index.m3u." -ForegroundColor Yellow
    exit 0
}

if (-not (Test-Path -LiteralPath $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir | Out-Null
}

$backupPath = Join-Path $BackupDir ("turktv_avant_import_index_{0}.m3u" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
Copy-Item -LiteralPath $PlaylistPath -Destination $backupPath -Force

$output = New-Object System.Collections.Generic.List[string]
foreach ($line in $playlistLines) { $output.Add($line) }
$output.Add("")
$output.Add("# Chaines ajoutees depuis index.m3u")
$output.Add(("# Date d'import: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")))

foreach ($entry in $toAdd) {
    foreach ($line in $entry.Lines) {
        $output.Add($line)
    }
}

Write-TextFile -Path $PlaylistPath -Lines $output

Write-Host ("Chaines dans turktv.m3u avant import: {0}" -f $playlistEntries.Count)
Write-Host ("Chaines dans index.m3u: {0}" -f $indexEntries.Count)
Write-Host ("Chaines ajoutees: {0}" -f $toAdd.Count) -ForegroundColor Green
Write-Host ("Sauvegarde: {0}" -f $backupPath)
Write-Host ""
Write-Host "Chaines ajoutees:"
foreach ($entry in $toAdd) {
    Write-Host ("- {0}" -f $entry.Name)
}
