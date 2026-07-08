$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$PlaylistPath = Join-Path $Root "turktv.m3u"
$BackupDir = Join-Path $Root "backups"
$RepositoryUrl = "https://github.com/SYNDICATCGTBEL/TURKTV.git"

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

function Get-AttributeValue {
    param(
        [string]$Line,
        [string]$Name
    )
    $pattern = '(?i)(?:^|\s)' + [regex]::Escape($Name) + '="([^"]*)"'
    $match = [regex]::Match($Line, $pattern)
    if ($match.Success) { return $match.Groups[1].Value }
    return ""
}

function Get-ChannelName {
    param([string]$Line)
    $commaIndex = $Line.LastIndexOf(",")
    if ($commaIndex -ge 0 -and $commaIndex -lt ($Line.Length - 1)) {
        return $Line.Substring($commaIndex + 1).Trim()
    }
    return ""
}

function Set-ChannelName {
    param(
        [string]$Line,
        [string]$Name
    )
    $commaIndex = $Line.LastIndexOf(",")
    if ($commaIndex -ge 0) {
        return $Line.Substring(0, $commaIndex + 1) + $Name.Trim()
    }
    return $Line + "," + $Name.Trim()
}

function Set-Logo {
    param(
        [string]$Line,
        [string]$Logo
    )

    if ($Logo -eq "-") {
        return ([regex]::Replace($Line, '\s+tvg-logo="[^"]*"', "")).TrimEnd()
    }

    if ([string]::IsNullOrWhiteSpace($Logo)) {
        return $Line
    }

    $safeLogo = $Logo.Trim().Replace('"', '')
    if ($Line -match '(?i)\s+tvg-logo="[^"]*"') {
        return [regex]::Replace($Line, '(?i)\s+tvg-logo="[^"]*"', ' tvg-logo="' + $safeLogo + '"', 1)
    }

    return [regex]::Replace($Line, '^#EXTINF:-1', '#EXTINF:-1 tvg-logo="' + $safeLogo + '"', 1)
}

function Get-Channels {
    param([string[]]$Lines)

    $channels = New-Object System.Collections.Generic.List[object]
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

        $channels.Add([pscustomobject]@{
            Number = $channels.Count + 1
            InfoLine = $i
            UrlLine = $urlLine
            Name = Get-ChannelName $Lines[$i]
            Logo = Get-AttributeValue -Line $Lines[$i] -Name "tvg-logo"
            Group = Get-AttributeValue -Line $Lines[$i] -Name "group-title"
            Url = $Lines[$urlLine].Trim()
        })
    }

    return $channels
}

function Assert-HttpUrl {
    param(
        [string]$Value,
        [string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    if ($Value -eq "-") { return }
    if ($Value -notmatch '^https?://') {
        throw "$Label doit commencer par http:// ou https://"
    }
}

function Publish-ToGitHub {
    param([string]$ChannelName)

    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $git) {
        Write-Host "Git n'est pas installe. Le fichier local est modifie, mais il n'est pas publie." -ForegroundColor Yellow
        return
    }

    Push-Location $Root
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $Root ".git\HEAD"))) {
            git init -b main | Out-Host
            git remote add origin $RepositoryUrl
        }

        $remote = git remote get-url origin 2>$null
        if ($LASTEXITCODE -ne 0) {
            git remote add origin $RepositoryUrl
        } elseif ($remote -ne $RepositoryUrl) {
            git remote set-url origin $RepositoryUrl
        }

        if (-not (git config user.name)) {
            git config user.name "SYNDICATCGTBEL"
        }
        if (-not (git config user.email)) {
            git config user.email "SYNDICATCGTBEL@users.noreply.github.com"
        }

        git add turktv.m3u README.md URL_BOITIER_IPTV.txt LIRE_MOI_TURKTV.txt Modifier_Chaine_TURKTV.cmd Modifier_Chaine_TURKTV.ps1 Verifier_Chaines_TURKTV.cmd Verifier_Chaines_TURKTV.ps1 Nettoyer_Chaines_TURKTV.cmd Nettoyer_Chaines_TURKTV.ps1 .gitignore | Out-Host
        git diff --cached --quiet
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Aucune modification a publier." -ForegroundColor Yellow
            return
        }

        $message = "Mise a jour TURKTV"
        if (-not [string]::IsNullOrWhiteSpace($ChannelName)) {
            $message = "Mise a jour $ChannelName"
        }

        git commit -m $message | Out-Host
        git branch -M main | Out-Host
        git push -u origin main | Out-Host

        Write-Host "Publication GitHub terminee." -ForegroundColor Green
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path -LiteralPath $PlaylistPath)) {
    throw "Fichier introuvable: $PlaylistPath"
}

$lines = Read-TextFile $PlaylistPath
$channels = @(Get-Channels $lines)

if ($channels.Count -eq 0) {
    throw "Aucune chaine trouvee dans turktv.m3u"
}

Clear-Host
Write-Host "TURKTV - modification d'une chaine" -ForegroundColor Cyan
Write-Host ""
Write-Host "Fichier modifie: $PlaylistPath"
Write-Host "Nombre de chaines: $($channels.Count)"
Write-Host ""

$search = Read-Host "Nom de la chaine a modifier"
if ([string]::IsNullOrWhiteSpace($search)) {
    Write-Host "Operation annulee."
    exit 0
}

$matches = @($channels | Where-Object { $_.Name -like "*$search*" } | Select-Object -First 30)
if ($matches.Count -eq 0) {
    Write-Host "Aucune chaine trouvee pour: $search" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
for ($i = 0; $i -lt $matches.Count; $i++) {
    $item = $matches[$i]
    Write-Host ("{0}. {1}" -f ($i + 1), $item.Name) -ForegroundColor Cyan
    Write-Host ("   Lien : {0}" -f $item.Url)
    if (-not [string]::IsNullOrWhiteSpace($item.Logo)) {
        Write-Host ("   Image: {0}" -f $item.Logo)
    }
}

Write-Host ""
$choiceText = Read-Host "Numero de la chaine a modifier"
$choice = 0
if (-not [int]::TryParse($choiceText, [ref]$choice) -or $choice -lt 1 -or $choice -gt $matches.Count) {
    Write-Host "Numero invalide." -ForegroundColor Red
    exit 1
}

$selected = $matches[$choice - 1]

Write-Host ""
Write-Host ("Chaine selectionnee: {0}" -f $selected.Name) -ForegroundColor Green
Write-Host "Laisse vide pour conserver la valeur actuelle."
Write-Host "Pour supprimer l'image, saisis seulement: -"
Write-Host ""

$newName = Read-Host ("Nouveau nom [{0}]" -f $selected.Name)
$newUrl = Read-Host "Nouveau lien video m3u8"
$newLogo = Read-Host "Nouvelle image/logo URL"

Assert-HttpUrl -Value $newUrl -Label "Le lien video"
Assert-HttpUrl -Value $newLogo -Label "L'image"

if ([string]::IsNullOrWhiteSpace($newName) -and [string]::IsNullOrWhiteSpace($newUrl) -and [string]::IsNullOrWhiteSpace($newLogo)) {
    Write-Host "Aucune modification saisie."
    exit 0
}

if (-not (Test-Path -LiteralPath $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir | Out-Null
}

$backupPath = Join-Path $BackupDir ("turktv_{0}.m3u" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
Copy-Item -LiteralPath $PlaylistPath -Destination $backupPath -Force

if (-not [string]::IsNullOrWhiteSpace($newName)) {
    $lines[$selected.InfoLine] = Set-ChannelName -Line $lines[$selected.InfoLine] -Name $newName
}

if (-not [string]::IsNullOrWhiteSpace($newLogo)) {
    $lines[$selected.InfoLine] = Set-Logo -Line $lines[$selected.InfoLine] -Logo $newLogo
}

if (-not [string]::IsNullOrWhiteSpace($newUrl)) {
    $lines[$selected.UrlLine] = $newUrl.Trim()
}

Write-TextFile -Path $PlaylistPath -Lines $lines

Write-Host ""
Write-Host "Modification enregistree." -ForegroundColor Green
Write-Host ("Sauvegarde creee: {0}" -f $backupPath)

$publish = Read-Host "Publier maintenant sur GitHub ? O/N"
if ($publish -match '^(o|oui|y|yes)$') {
    $publishedName = $selected.Name
    if (-not [string]::IsNullOrWhiteSpace($newName)) { $publishedName = $newName }
    Publish-ToGitHub -ChannelName $publishedName
} else {
    Write-Host "Modification locale uniquement. Le boitier ne la verra pas tant qu'elle n'est pas publiee sur GitHub." -ForegroundColor Yellow
}
