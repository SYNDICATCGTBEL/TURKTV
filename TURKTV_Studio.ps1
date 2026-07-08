param(
    [switch]$SelfTest,
    [switch]$SmokeTest
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$PlaylistPath = Join-Path $Root "turktv.m3u"
$IndexPath = Join-Path $Root "index.m3u"
$BackupDir = Join-Path $Root "backups"
$PlayerHtmlPath = Join-Path $Root "lecteur_turktv.html"
$RepositoryUrl = "https://github.com/SYNDICATCGTBEL/TURKTV.git"
$PublicSources = @(
    "https://iptv-org.github.io/iptv/countries/tr.m3u"
)

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

function Get-WebText {
    param([string]$Url)

    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 30 -Headers @{ "User-Agent" = "Mozilla/5.0 TURKTV-Studio" }
    if ($response.Content -is [byte[]]) {
        return [System.Text.Encoding]::UTF8.GetString($response.Content)
    }
    return [string]$response.Content
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

function Format-M3UEntry {
    param([object]$Entry)

    $attributes = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Entry.Logo)) {
        $attributes.Add(('tvg-logo="{0}"' -f ([string]$Entry.Logo).Replace('"', '')))
    }
    if (-not [string]::IsNullOrWhiteSpace($Entry.Group)) {
        $attributes.Add(('group-title="{0}"' -f ([string]$Entry.Group).Replace('"', '')))
    }

    $prefix = "#EXTINF:-1"
    if ($attributes.Count -gt 0) {
        $prefix += " " + ($attributes -join " ")
    }

    return @(
        ($prefix + "," + $Entry.Name),
        $Entry.Url
    )
}

function Get-M3UEntries {
    param(
        [string[]]$Lines,
        [string]$Source = "local"
    )

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
        $logo = Get-AttributeValue -Line $Lines[$i] -Name "tvg-logo"
        $group = Get-AttributeValue -Line $Lines[$i] -Name "group-title"

        $entries.Add([pscustomobject]@{
            Number = $entries.Count + 1
            InfoLine = $i
            UrlLine = $urlLine
            Name = $name
            Group = $group
            Logo = $logo
            Url = $url
            Source = $Source
            Key = Normalize-Name $name
            UrlKey = $url.ToLowerInvariant()
            Status = ""
            Message = ""
        })
    }

    return $entries
}

function Backup-Playlist {
    param([string]$Label)
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir | Out-Null
    }
    $safeLabel = $Label -replace '[^A-Za-z0-9_-]+', '_'
    $backupPath = Join-Path $BackupDir ("turktv_{0}_{1}.m3u" -f $safeLabel, (Get-Date -Format "yyyyMMdd_HHmmss"))
    Copy-Item -LiteralPath $PlaylistPath -Destination $backupPath -Force
    return $backupPath
}

function Test-StreamUrl {
    param(
        [string]$Url,
        [int]$TimeoutMs = 9000
    )

    $result = [pscustomobject]@{
        Ok = $false
        Status = ""
        ContentType = ""
        Message = ""
    }

    try {
        if ([string]::IsNullOrWhiteSpace($Url) -or $Url -notmatch '^https?://') {
            throw "URL invalide"
        }

        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        } catch {}

        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = "GET"
        $request.Timeout = $TimeoutMs
        $request.ReadWriteTimeout = $TimeoutMs
        $request.AllowAutoRedirect = $true
        $request.UserAgent = "VLC/3.0.18 LibVLC/3.0.18"
        try { $request.Headers.Add("Range", "bytes=0-4095") } catch {}

        $response = $request.GetResponse()
        $result.Status = [int]$response.StatusCode
        $result.ContentType = [string]$response.ContentType

        $stream = $response.GetResponseStream()
        $buffer = New-Object byte[] 4096
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $bodyStart = ""
        if ($read -gt 0) {
            $bodyStart = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        }
        $response.Close()

        if ($result.Status -ge 200 -and $result.Status -lt 400) {
            if ($Url -match '\.m3u8(\?|$)' -or $result.ContentType -match 'mpegurl|application/vnd.apple|application/x-mpegURL|audio/mpegurl' -or $bodyStart -match '#EXTM3U|#EXT-X-') {
                $result.Ok = $true
                $result.Message = "OK"
            } else {
                $result.Message = "Reponse recue, mais pas une playlist HLS claire"
            }
        } else {
            $result.Message = "HTTP $($result.Status)"
        }
    } catch {
        $result.Message = $_.Exception.Message
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $result.Status = [int]$_.Exception.Response.StatusCode
        }
    }

    return $result
}

function Find-Vlc {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:ProgramFiles) {
        $candidates.Add((Join-Path $env:ProgramFiles "VideoLAN\VLC\vlc.exe"))
    }
    $programFilesX86 = ${env:ProgramFiles(x86)}
    if ($programFilesX86) {
        $candidates.Add((Join-Path $programFilesX86 "VideoLAN\VLC\vlc.exe"))
    }
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
  <title>TURKTV - Lecteur</title>
  <style>
    body { margin: 0; font-family: Arial, sans-serif; background: #101418; color: #f4f7fb; }
    main { max-width: 1120px; margin: 0 auto; padding: 18px; }
    video { width: 100%; max-height: 74vh; background: #000; }
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
      statusEl.textContent = 'Ce navigateur ne lit pas ce flux HLS. VLC reste le test le plus fiable.';
    }
  </script>
</body>
</html>
"@
    [System.IO.File]::WriteAllText($PlayerHtmlPath, $html, [System.Text.Encoding]::UTF8)
}

function Extract-StreamsFromText {
    param(
        [string]$Text,
        [string]$Source
    )

    $clean = $Text -replace '\\/', '/'
    $clean = [System.Net.WebUtility]::HtmlDecode($clean)
    $lines = $clean -split "`r?`n"
    $entries = @(Get-M3UEntries -Lines $lines -Source $Source)
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($entry in $entries) {
        $results.Add($entry)
    }

    $regex = [regex]'https?://[^\s''"<>]+?\.m3u8(?:\?[^\s''"<>]*)?'
    foreach ($match in $regex.Matches($clean)) {
        $url = $match.Value.Trim()
        if ($results | Where-Object { $_.Url -eq $url } | Select-Object -First 1) {
            continue
        }

        $uri = $null
        $name = "Flux extrait"
        if ([Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) {
            $name = $uri.Host -replace '^www\.', ''
        }

        $results.Add([pscustomobject]@{
            Number = $results.Count + 1
            InfoLine = -1
            UrlLine = -1
            Name = $name
            Group = "Extrait"
            Logo = ""
            Url = $url
            Source = $Source
            Key = Normalize-Name $name
            UrlKey = $url.ToLowerInvariant()
            Status = ""
            Message = ""
        })
    }

    return $results
}

function Publish-ToGitHub {
    param([scriptblock]$Log)

    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $git) {
        & $Log "Git n'est pas installe. Publication impossible."
        return
    }

    Push-Location $Root
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $Root ".git\HEAD"))) {
            git init -b main | Out-Null
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

        git add turktv.m3u index.m3u README.md URL_BOITIER_IPTV.txt LIRE_MOI_TURKTV.txt Modifier_Chaine_TURKTV.cmd Modifier_Chaine_TURKTV.ps1 Verifier_Chaines_TURKTV.cmd Verifier_Chaines_TURKTV.ps1 Nettoyer_Chaines_TURKTV.cmd Nettoyer_Chaines_TURKTV.ps1 Importer_Index_TURKTV.cmd Importer_Index_TURKTV.ps1 Tester_Lecteur_TURKTV.cmd Tester_Lecteur_TURKTV.ps1 TURKTV_Studio.cmd TURKTV_Studio.ps1 .gitignore | Out-Null
        git diff --cached --quiet
        if ($LASTEXITCODE -eq 0) {
            & $Log "Aucune modification a publier."
            return
        }

        git commit -m "Mise a jour TURKTV Studio" | Out-Null
        git branch -M main | Out-Null
        git push -u origin main | Out-Null
        & $Log "Publication GitHub terminee."
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path -LiteralPath $PlaylistPath)) {
    throw "Fichier introuvable: $PlaylistPath"
}

if ($SelfTest) {
    $channels = @(Get-M3UEntries -Lines (Read-TextFile $PlaylistPath) -Source "turktv.m3u")
    if ($channels.Count -eq 0) { throw "Aucune chaine dans turktv.m3u" }
    Write-Host ("SelfTest OK - {0} chaines chargees." -f $channels.Count)
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

if (-not ("Win32WindowTools" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32WindowTools {
    [DllImport("user32.dll")]
    public static extern IntPtr SetParent(IntPtr hWnd, IntPtr hWndNewParent);
    [DllImport("user32.dll")]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
}
"@
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Channels = @()
$script:Candidates = @()
$script:VlcProcess = $null
$script:VlcHandle = [IntPtr]::Zero

$form = New-Object System.Windows.Forms.Form
$form.Text = "TURKTV Studio - controle, lecteur et extraction M3U"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(1280, 780)
$form.MinimumSize = New-Object System.Drawing.Size(1080, 680)

$main = New-Object System.Windows.Forms.SplitContainer
$main.Dock = "Fill"
$form.Controls.Add($main)
$form.Add_Shown({
    try {
        $main.Panel1MinSize = 340
        $main.Panel2MinSize = 420
        $main.SplitterDistance = 520
    } catch {}
})

$leftTop = New-Object System.Windows.Forms.Panel
$leftTop.Dock = "Top"
$leftTop.Height = 92
$main.Panel1.Controls.Add($leftTop)

$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = "Recherche chaine"
$lblSearch.Location = New-Object System.Drawing.Point(10, 12)
$lblSearch.AutoSize = $true
$leftTop.Controls.Add($lblSearch)

$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Location = New-Object System.Drawing.Point(10, 34)
$txtSearch.Size = New-Object System.Drawing.Size(310, 24)
$leftTop.Controls.Add($txtSearch)

$btnReload = New-Object System.Windows.Forms.Button
$btnReload.Text = "Recharger"
$btnReload.Location = New-Object System.Drawing.Point(330, 32)
$btnReload.Size = New-Object System.Drawing.Size(86, 28)
$leftTop.Controls.Add($btnReload)

$btnPublish = New-Object System.Windows.Forms.Button
$btnPublish.Text = "Publier GitHub"
$btnPublish.Location = New-Object System.Drawing.Point(420, 32)
$btnPublish.Size = New-Object System.Drawing.Size(96, 28)
$leftTop.Controls.Add($btnPublish)

$lblStats = New-Object System.Windows.Forms.Label
$lblStats.Location = New-Object System.Drawing.Point(10, 66)
$lblStats.Size = New-Object System.Drawing.Size(500, 18)
$leftTop.Controls.Add($lblStats)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = "Fill"
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.ReadOnly = $true
$grid.SelectionMode = "FullRowSelect"
$grid.MultiSelect = $false
$grid.AutoSizeColumnsMode = "Fill"
$grid.RowHeadersVisible = $false
[void]$grid.Columns.Add("Name", "Chaine")
[void]$grid.Columns.Add("Group", "Groupe")
[void]$grid.Columns.Add("Status", "Test")
[void]$grid.Columns.Add("Url", "Lien")
$grid.Columns["Name"].FillWeight = 34
$grid.Columns["Group"].FillWeight = 20
$grid.Columns["Status"].FillWeight = 13
$grid.Columns["Url"].FillWeight = 60
$main.Panel1.Controls.Add($grid)
$grid.BringToFront()

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = "Fill"
$main.Panel2.Controls.Add($tabs)

$tabPlayer = New-Object System.Windows.Forms.TabPage
$tabPlayer.Text = "Lecteur"
$tabs.TabPages.Add($tabPlayer)

$playerPanel = New-Object System.Windows.Forms.Panel
$playerPanel.Dock = "Fill"
$playerPanel.BackColor = [System.Drawing.Color]::Black
$tabPlayer.Controls.Add($playerPanel)

$playerLabel = New-Object System.Windows.Forms.Label
$playerLabel.Text = "Selectionne une chaine puis clique sur Lire. VLC sera integre ici si VLC est installe."
$playerLabel.ForeColor = [System.Drawing.Color]::White
$playerLabel.BackColor = [System.Drawing.Color]::Black
$playerLabel.AutoSize = $false
$playerLabel.TextAlign = "MiddleCenter"
$playerLabel.Dock = "Fill"
$playerPanel.Controls.Add($playerLabel)

$playerButtons = New-Object System.Windows.Forms.Panel
$playerButtons.Dock = "Bottom"
$playerButtons.Height = 58
$tabPlayer.Controls.Add($playerButtons)
$playerButtons.BringToFront()

$btnPlay = New-Object System.Windows.Forms.Button
$btnPlay.Text = "Lire"
$btnPlay.Location = New-Object System.Drawing.Point(12, 14)
$btnPlay.Size = New-Object System.Drawing.Size(86, 30)
$playerButtons.Controls.Add($btnPlay)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = "Stop"
$btnStop.Location = New-Object System.Drawing.Point(104, 14)
$btnStop.Size = New-Object System.Drawing.Size(86, 30)
$playerButtons.Controls.Add($btnStop)

$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text = "Tester lien"
$btnTest.Location = New-Object System.Drawing.Point(196, 14)
$btnTest.Size = New-Object System.Drawing.Size(96, 30)
$playerButtons.Controls.Add($btnTest)

$btnEdit = New-Object System.Windows.Forms.Button
$btnEdit.Text = "Modifier"
$btnEdit.Location = New-Object System.Drawing.Point(298, 14)
$btnEdit.Size = New-Object System.Drawing.Size(96, 30)
$playerButtons.Controls.Add($btnEdit)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = "Copier lien"
$btnCopy.Location = New-Object System.Drawing.Point(400, 14)
$btnCopy.Size = New-Object System.Drawing.Size(96, 30)
$playerButtons.Controls.Add($btnCopy)

$btnBrowser = New-Object System.Windows.Forms.Button
$btnBrowser.Text = "Navigateur"
$btnBrowser.Location = New-Object System.Drawing.Point(502, 14)
$btnBrowser.Size = New-Object System.Drawing.Size(96, 30)
$playerButtons.Controls.Add($btnBrowser)

$tabExtract = New-Object System.Windows.Forms.TabPage
$tabExtract.Text = "Recherche / extraction"
$tabs.TabPages.Add($tabExtract)

$extractTop = New-Object System.Windows.Forms.Panel
$extractTop.Dock = "Top"
$extractTop.Height = 118
$tabExtract.Controls.Add($extractTop)

$btnPublicSearch = New-Object System.Windows.Forms.Button
$btnPublicSearch.Text = "Rechercher flux publics turcs"
$btnPublicSearch.Location = New-Object System.Drawing.Point(12, 12)
$btnPublicSearch.Size = New-Object System.Drawing.Size(210, 30)
$extractTop.Controls.Add($btnPublicSearch)

$btnIndexSearch = New-Object System.Windows.Forms.Button
$btnIndexSearch.Text = "Comparer index.m3u"
$btnIndexSearch.Location = New-Object System.Drawing.Point(230, 12)
$btnIndexSearch.Size = New-Object System.Drawing.Size(150, 30)
$extractTop.Controls.Add($btnIndexSearch)

$lblUrl = New-Object System.Windows.Forms.Label
$lblUrl.Text = "Page web, API ou fichier M3U a analyser"
$lblUrl.Location = New-Object System.Drawing.Point(12, 54)
$lblUrl.AutoSize = $true
$extractTop.Controls.Add($lblUrl)

$txtExtractUrl = New-Object System.Windows.Forms.TextBox
$txtExtractUrl.Location = New-Object System.Drawing.Point(12, 76)
$txtExtractUrl.Size = New-Object System.Drawing.Size(430, 24)
$extractTop.Controls.Add($txtExtractUrl)

$btnExtractUrl = New-Object System.Windows.Forms.Button
$btnExtractUrl.Text = "Extraire"
$btnExtractUrl.Location = New-Object System.Drawing.Point(450, 74)
$btnExtractUrl.Size = New-Object System.Drawing.Size(92, 28)
$extractTop.Controls.Add($btnExtractUrl)

$btnAddCandidates = New-Object System.Windows.Forms.Button
$btnAddCandidates.Text = "Ajouter selection"
$btnAddCandidates.Location = New-Object System.Drawing.Point(550, 74)
$btnAddCandidates.Size = New-Object System.Drawing.Size(124, 28)
$extractTop.Controls.Add($btnAddCandidates)

$candidateGrid = New-Object System.Windows.Forms.DataGridView
$candidateGrid.Dock = "Fill"
$candidateGrid.AllowUserToAddRows = $false
$candidateGrid.AllowUserToDeleteRows = $false
$candidateGrid.ReadOnly = $true
$candidateGrid.SelectionMode = "FullRowSelect"
$candidateGrid.MultiSelect = $true
$candidateGrid.AutoSizeColumnsMode = "Fill"
$candidateGrid.RowHeadersVisible = $false
[void]$candidateGrid.Columns.Add("Name", "Nom")
[void]$candidateGrid.Columns.Add("Source", "Source")
[void]$candidateGrid.Columns.Add("Status", "Test")
[void]$candidateGrid.Columns.Add("Url", "Lien")
$candidateGrid.Columns["Name"].FillWeight = 28
$candidateGrid.Columns["Source"].FillWeight = 20
$candidateGrid.Columns["Status"].FillWeight = 12
$candidateGrid.Columns["Url"].FillWeight = 58
$tabExtract.Controls.Add($candidateGrid)
$candidateGrid.BringToFront()

$candidateBottom = New-Object System.Windows.Forms.Panel
$candidateBottom.Dock = "Bottom"
$candidateBottom.Height = 50
$tabExtract.Controls.Add($candidateBottom)
$candidateBottom.BringToFront()

$btnTestCandidate = New-Object System.Windows.Forms.Button
$btnTestCandidate.Text = "Tester selection"
$btnTestCandidate.Location = New-Object System.Drawing.Point(12, 10)
$btnTestCandidate.Size = New-Object System.Drawing.Size(128, 30)
$candidateBottom.Controls.Add($btnTestCandidate)

$btnPlayCandidate = New-Object System.Windows.Forms.Button
$btnPlayCandidate.Text = "Lire selection"
$btnPlayCandidate.Location = New-Object System.Drawing.Point(148, 10)
$btnPlayCandidate.Size = New-Object System.Drawing.Size(120, 30)
$candidateBottom.Controls.Add($btnPlayCandidate)

$tabLog = New-Object System.Windows.Forms.TabPage
$tabLog.Text = "Journal"
$tabs.TabPages.Add($tabLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Dock = "Fill"
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$tabLog.Controls.Add($txtLog)

function Add-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    $txtLog.AppendText($line + [Environment]::NewLine)
}

function Get-SelectedChannel {
    if ($grid.SelectedRows.Count -eq 0) { return $null }
    return $grid.SelectedRows[0].Tag
}

function Get-SelectedCandidate {
    if ($candidateGrid.SelectedRows.Count -eq 0) { return $null }
    return $candidateGrid.SelectedRows[0].Tag
}

function Refresh-ChannelGrid {
    param([string]$Filter = "")

    $grid.Rows.Clear()
    $items = $script:Channels
    if (-not [string]::IsNullOrWhiteSpace($Filter)) {
        $items = @($items | Where-Object { $_.Name -like "*$Filter*" -or $_.Group -like "*$Filter*" -or $_.Url -like "*$Filter*" })
    }

    foreach ($item in $items) {
        $rowIndex = $grid.Rows.Add($item.Name, $item.Group, $item.Status, $item.Url)
        $grid.Rows[$rowIndex].Tag = $item
    }

    $lblStats.Text = ("Playlist: {0} chaines | Affichees: {1}" -f $script:Channels.Count, $items.Count)
}

function Load-Playlist {
    $script:Channels = @(Get-M3UEntries -Lines (Read-TextFile $PlaylistPath) -Source "turktv.m3u")
    Refresh-ChannelGrid -Filter $txtSearch.Text
    Add-Log ("Playlist chargee: {0} chaines." -f $script:Channels.Count)
}

function Refresh-CandidateGrid {
    $candidateGrid.Rows.Clear()
    foreach ($item in $script:Candidates) {
        $rowIndex = $candidateGrid.Rows.Add($item.Name, $item.Source, $item.Status, $item.Url)
        $candidateGrid.Rows[$rowIndex].Tag = $item
    }
    Add-Log ("Candidats affiches: {0}" -f $script:Candidates.Count)
}

function Existing-KeySets {
    $names = New-Object System.Collections.Generic.HashSet[string]
    $urls = New-Object System.Collections.Generic.HashSet[string]
    foreach ($channel in $script:Channels) {
        if (-not [string]::IsNullOrWhiteSpace($channel.Key)) { [void]$names.Add($channel.Key) }
        if (-not [string]::IsNullOrWhiteSpace($channel.UrlKey)) { [void]$urls.Add($channel.UrlKey) }
    }
    return [pscustomobject]@{ Names = $names; Urls = $urls }
}

function Filter-NewEntries {
    param([object[]]$Entries)

    $sets = Existing-KeySets
    $addedNames = New-Object System.Collections.Generic.HashSet[string]
    $addedUrls = New-Object System.Collections.Generic.HashSet[string]
    $filtered = New-Object System.Collections.Generic.List[object]

    foreach ($entry in $Entries) {
        if ([string]::IsNullOrWhiteSpace($entry.Key) -or [string]::IsNullOrWhiteSpace($entry.UrlKey)) { continue }
        if ($sets.Names.Contains($entry.Key) -or $sets.Urls.Contains($entry.UrlKey)) { continue }
        if ($addedNames.Contains($entry.Key) -or $addedUrls.Contains($entry.UrlKey)) { continue }
        [void]$addedNames.Add($entry.Key)
        [void]$addedUrls.Add($entry.UrlKey)
        $filtered.Add($entry)
    }

    return $filtered
}

function Stop-Player {
    try {
        if ($script:VlcProcess -and -not $script:VlcProcess.HasExited) {
            $script:VlcProcess.CloseMainWindow() | Out-Null
            Start-Sleep -Milliseconds 400
            if (-not $script:VlcProcess.HasExited) {
                $script:VlcProcess.Kill()
            }
        }
    } catch {}

    $script:VlcProcess = $null
    $script:VlcHandle = [IntPtr]::Zero
    $playerLabel.Visible = $true
}

function Resize-EmbeddedPlayer {
    if ($script:VlcHandle -ne [IntPtr]::Zero) {
        [Win32WindowTools]::MoveWindow($script:VlcHandle, 0, 0, $playerPanel.ClientSize.Width, $playerPanel.ClientSize.Height, $true) | Out-Null
    }
}

function Play-Url {
    param(
        [string]$Name,
        [string]$Url
    )

    Stop-Player
    $vlc = Find-Vlc
    if ([string]::IsNullOrWhiteSpace($vlc)) {
        Write-HtmlPlayer -Name $Name -Url $Url
        Start-Process -FilePath $PlayerHtmlPath
        Add-Log "VLC absent: lecteur HTML ouvert dans le navigateur."
        return
    }

    $playerLabel.Visible = $false
    $script:VlcProcess = Start-Process -FilePath $vlc -ArgumentList @("--no-video-title-show", "--no-qt-privacy-ask", "--no-qt-updates-notif", $Url) -PassThru
    $handle = [IntPtr]::Zero
    for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 120
        try {
            $script:VlcProcess.Refresh()
            if ($script:VlcProcess.MainWindowHandle -ne 0) {
                $handle = $script:VlcProcess.MainWindowHandle
                break
            }
        } catch {}
    }

    if ($handle -eq [IntPtr]::Zero) {
        Add-Log "VLC ouvert, mais impossible de l'integrer dans la fenetre."
        return
    }

    $script:VlcHandle = $handle
    [Win32WindowTools]::SetParent($handle, $playerPanel.Handle) | Out-Null
    Resize-EmbeddedPlayer
    Add-Log ("Lecture lancee: {0}" -f $Name)
}

function Edit-SelectedChannel {
    $selected = Get-SelectedChannel
    if (-not $selected) { return }

    $newName = [Microsoft.VisualBasic.Interaction]::InputBox("Nom de la chaine", "Modifier", $selected.Name)
    if ([string]::IsNullOrWhiteSpace($newName)) { return }
    $newUrl = [Microsoft.VisualBasic.Interaction]::InputBox("Lien video m3u8", "Modifier", $selected.Url)
    if ([string]::IsNullOrWhiteSpace($newUrl) -or $newUrl -notmatch '^https?://') {
        [System.Windows.Forms.MessageBox]::Show("Le lien doit commencer par http:// ou https://", "Lien invalide") | Out-Null
        return
    }
    $newLogo = [Microsoft.VisualBasic.Interaction]::InputBox("Image/logo URL (optionnel)", "Modifier", $selected.Logo)

    $backup = Backup-Playlist -Label "avant_modification_studio"
    $lines = Read-TextFile $PlaylistPath
    $lines[$selected.InfoLine] = Format-M3UEntry ([pscustomobject]@{
        Name = $newName
        Url = $newUrl
        Logo = $newLogo
        Group = $selected.Group
    }) | Select-Object -First 1
    $lines[$selected.UrlLine] = $newUrl
    Write-TextFile -Path $PlaylistPath -Lines $lines
    Add-Log ("Chaine modifiee: {0}. Sauvegarde: {1}" -f $newName, $backup)
    Load-Playlist
}

function Add-CandidatesToPlaylist {
    $selectedRows = @($candidateGrid.SelectedRows)
    if ($selectedRows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Selectionne au moins une ligne a ajouter.", "Aucune selection") | Out-Null
        return
    }

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($row in $selectedRows) {
        if ($row.Tag) { $entries.Add($row.Tag) }
    }

    $newEntries = @(Filter-NewEntries -Entries $entries)
    if ($newEntries.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Aucune chaine nouvelle a ajouter.", "Doublons") | Out-Null
        return
    }

    $backup = Backup-Playlist -Label "avant_ajout_studio"
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Read-TextFile $PlaylistPath)) { $lines.Add($line) }
    $lines.Add("")
    $lines.Add("# Chaines ajoutees depuis TURKTV Studio")
    $lines.Add(("# Date d'ajout: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")))

    foreach ($entry in $newEntries) {
        foreach ($line in (Format-M3UEntry $entry)) {
            $lines.Add($line)
        }
    }

    Write-TextFile -Path $PlaylistPath -Lines $lines
    Add-Log ("{0} chaine(s) ajoutee(s). Sauvegarde: {1}" -f $newEntries.Count, $backup)
    Load-Playlist
}

$txtSearch.Add_TextChanged({ Refresh-ChannelGrid -Filter $txtSearch.Text })
$btnReload.Add_Click({ Load-Playlist })
$btnPublish.Add_Click({
    Add-Log "Publication GitHub en cours..."
    try { Publish-ToGitHub -Log ${function:Add-Log} } catch { Add-Log ("Erreur publication: " + $_.Exception.Message) }
})

$btnPlay.Add_Click({
    $selected = Get-SelectedChannel
    if ($selected) { Play-Url -Name $selected.Name -Url $selected.Url }
})
$btnStop.Add_Click({ Stop-Player; Add-Log "Lecture arretee." })
$btnBrowser.Add_Click({
    $selected = Get-SelectedChannel
    if ($selected) {
        Write-HtmlPlayer -Name $selected.Name -Url $selected.Url
        Start-Process -FilePath $PlayerHtmlPath
        Add-Log "Lecteur HTML ouvert."
    }
})
$btnCopy.Add_Click({
    $selected = Get-SelectedChannel
    if ($selected) {
        Set-Clipboard -Value $selected.Url
        Add-Log "Lien copie dans le presse-papiers."
    }
})
$btnTest.Add_Click({
    $selected = Get-SelectedChannel
    if (-not $selected) { return }
    Add-Log ("Test: {0}" -f $selected.Name)
    $result = Test-StreamUrl -Url $selected.Url
    $selected.Status = if ($result.Ok) { "OK" } else { "ERREUR" }
    $selected.Message = $result.Message
    Refresh-ChannelGrid -Filter $txtSearch.Text
    Add-Log ("Resultat: {0} - {1}" -f $selected.Status, $result.Message)
})
$btnEdit.Add_Click({ Edit-SelectedChannel })
$playerPanel.Add_Resize({ Resize-EmbeddedPlayer })
$form.Add_FormClosing({ Stop-Player })

$btnPublicSearch.Add_Click({
    try {
        Add-Log "Recherche dans les sources publiques turques..."
        $all = New-Object System.Collections.Generic.List[object]
        foreach ($source in $PublicSources) {
            Add-Log ("Telechargement: {0}" -f $source)
            $content = Get-WebText -Url $source
            foreach ($entry in (Get-M3UEntries -Lines ($content -split "`r?`n") -Source $source)) {
                $all.Add($entry)
            }
        }
        $script:Candidates = @(Filter-NewEntries -Entries $all)
        Refresh-CandidateGrid
    } catch {
        Add-Log ("Erreur recherche publique: " + $_.Exception.Message)
    }
})

$btnIndexSearch.Add_Click({
    try {
        if (-not (Test-Path -LiteralPath $IndexPath)) { throw "index.m3u introuvable" }
        $entries = @(Get-M3UEntries -Lines (Read-TextFile $IndexPath) -Source "index.m3u")
        $script:Candidates = @(Filter-NewEntries -Entries $entries)
        Refresh-CandidateGrid
    } catch {
        Add-Log ("Erreur index.m3u: " + $_.Exception.Message)
    }
})

$btnExtractUrl.Add_Click({
    try {
        $url = $txtExtractUrl.Text.Trim()
        if ($url -notmatch '^https?://') {
            [System.Windows.Forms.MessageBox]::Show("Saisis une URL http:// ou https://", "URL invalide") | Out-Null
            return
        }
        Add-Log ("Extraction depuis: {0}" -f $url)
        $content = Get-WebText -Url $url
        $script:Candidates = @(Filter-NewEntries -Entries (Extract-StreamsFromText -Text $content -Source $url))
        Refresh-CandidateGrid
    } catch {
        Add-Log ("Erreur extraction: " + $_.Exception.Message)
    }
})

$btnAddCandidates.Add_Click({ Add-CandidatesToPlaylist })
$btnTestCandidate.Add_Click({
    $selected = Get-SelectedCandidate
    if (-not $selected) { return }
    Add-Log ("Test candidat: {0}" -f $selected.Name)
    $result = Test-StreamUrl -Url $selected.Url
    $selected.Status = if ($result.Ok) { "OK" } else { "ERREUR" }
    $selected.Message = $result.Message
    Refresh-CandidateGrid
    Add-Log ("Resultat candidat: {0} - {1}" -f $selected.Status, $result.Message)
})
$btnPlayCandidate.Add_Click({
    $selected = Get-SelectedCandidate
    if ($selected) {
        $tabs.SelectedTab = $tabPlayer
        Play-Url -Name $selected.Name -Url $selected.Url
    }
})

Load-Playlist
$vlcPath = Find-Vlc
if ([string]::IsNullOrWhiteSpace($vlcPath)) {
    Add-Log "VLC: non trouve, lecteur HTML en secours."
} else {
    Add-Log ("VLC: {0}" -f $vlcPath)
}

if ($SmokeTest) {
    Write-Host "SmokeTest OK - interface initialisee."
    $form.Dispose()
    exit 0
}

[System.Windows.Forms.Application]::Run($form)
