$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$PlaylistPath = Join-Path $Root "turktv.m3u"
$PlayerPath = Join-Path $Root "lecteur_turktv.html"

function Read-TextFile {
    param([string]$Path)
    return [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
}

function Get-ChannelName {
    param([string]$Line)
    $commaIndex = $Line.LastIndexOf(",")
    if ($commaIndex -ge 0 -and $commaIndex -lt ($Line.Length - 1)) {
        return $Line.Substring($commaIndex + 1).Trim()
    }
    return ""
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
            Name = Get-ChannelName $Lines[$i]
            Url = $Lines[$urlLine].Trim()
        })
    }

    return $channels
}

function Find-Vlc {
    $candidates = @(
        (Join-Path $env:ProgramFiles "VideoLAN\VLC\vlc.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "VideoLAN\VLC\vlc.exe")
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }

    $cmd = Get-Command vlc.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return ""
}

function Write-HtmlPlayer {
    param(
        [string]$Name,
        [string]$Url
    )

    $encodedName = [System.Net.WebUtility]::HtmlEncode($Name)
    $encodedUrl = [System.Net.WebUtility]::HtmlEncode($Url)
    $jsonUrl = $Url.Replace("\", "\\").Replace("'", "\'")

    $html = @"
<!doctype html>
<html lang="fr">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>TURKTV - Test lecteur</title>
  <style>
    body { margin: 0; font-family: Arial, sans-serif; background: #101418; color: #f4f7fb; }
    main { max-width: 980px; margin: 0 auto; padding: 24px; }
    video { width: 100%; max-height: 70vh; background: #000; }
    code { overflow-wrap: anywhere; color: #b9d7ff; }
    .status { margin: 12px 0; color: #ffd98a; }
  </style>
</head>
<body>
  <main>
    <h1>$encodedName</h1>
    <p><code>$encodedUrl</code></p>
    <div id="status" class="status">Chargement du flux...</div>
    <video id="video" controls autoplay playsinline></video>
  </main>
  <script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
  <script>
    const url = '$jsonUrl';
    const video = document.getElementById('video');
    const statusEl = document.getElementById('status');

    if (video.canPlayType('application/vnd.apple.mpegurl')) {
      video.src = url;
      statusEl.textContent = 'Lecture native du navigateur.';
    } else if (window.Hls && Hls.isSupported()) {
      const hls = new Hls();
      hls.loadSource(url);
      hls.attachMedia(video);
      hls.on(Hls.Events.ERROR, function (_, data) {
        statusEl.textContent = 'Erreur lecteur: ' + data.type + ' / ' + data.details;
      });
      hls.on(Hls.Events.MANIFEST_PARSED, function () {
        statusEl.textContent = 'Flux charge. Si l image ne demarre pas, clique sur lecture.';
        video.play().catch(() => {});
      });
    } else {
      statusEl.textContent = 'Ce navigateur ne sait pas lire ce flux HLS. Installe VLC pour un test plus fiable.';
    }
  </script>
</body>
</html>
"@

    [System.IO.File]::WriteAllText($PlayerPath, $html, [System.Text.Encoding]::UTF8)
}

if (-not (Test-Path -LiteralPath $PlaylistPath)) {
    throw "Fichier introuvable: $PlaylistPath"
}

$channels = @(Get-Channels (Read-TextFile $PlaylistPath))
if ($channels.Count -eq 0) {
    throw "Aucune chaine trouvee dans turktv.m3u"
}

Clear-Host
Write-Host "TURKTV - tester une chaine dans un lecteur" -ForegroundColor Cyan
Write-Host ""
Write-Host ("Nombre de chaines: {0}" -f $channels.Count)
Write-Host ""

$search = Read-Host "Nom de la chaine a tester"
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
    Write-Host ("   {0}" -f $item.Url)
}

Write-Host ""
$choiceText = Read-Host "Numero de la chaine a tester"
$choice = 0
if (-not [int]::TryParse($choiceText, [ref]$choice) -or $choice -lt 1 -or $choice -gt $matches.Count) {
    Write-Host "Numero invalide." -ForegroundColor Red
    exit 1
}

$selected = $matches[$choice - 1]
$vlc = Find-Vlc

Write-Host ""
Write-Host ("Chaine: {0}" -f $selected.Name) -ForegroundColor Green
Write-Host ("Lien: {0}" -f $selected.Url)
Write-Host ""
Write-Host "1 - Tester avec VLC si disponible"
Write-Host "2 - Tester dans un lecteur HTML navigateur"
Write-Host "3 - Copier/afficher seulement le lien"
Write-Host ""
$mode = Read-Host "Votre choix"

if ($mode -eq "1") {
    if ([string]::IsNullOrWhiteSpace($vlc)) {
        Write-Host "VLC n'est pas trouve sur ce PC. Ouverture du lecteur HTML a la place." -ForegroundColor Yellow
        Write-HtmlPlayer -Name $selected.Name -Url $selected.Url
        Start-Process -FilePath $PlayerPath
    } else {
        Start-Process -FilePath $vlc -ArgumentList @($selected.Url)
        Write-Host "VLC ouvert."
    }
} elseif ($mode -eq "2") {
    Write-HtmlPlayer -Name $selected.Name -Url $selected.Url
    Start-Process -FilePath $PlayerPath
    Write-Host ("Lecteur HTML ouvert: {0}" -f $PlayerPath)
} else {
    Set-Clipboard -Value $selected.Url
    Write-Host "Lien copie dans le presse-papiers."
}
