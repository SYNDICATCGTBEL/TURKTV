$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$PlaylistPath = Join-Path $Root "turktv.m3u"
$ReportCsv = Join-Path $Root "rapport_chaines.csv"
$ReportTxt = Join-Path $Root "chaines_a_corriger.txt"
$Parallel = 12
$TimeoutMs = 8000

function Read-TextFile {
    param([string]$Path)
    return [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
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
            Group = Get-AttributeValue -Line $Lines[$i] -Name "group-title"
            Url = $Lines[$urlLine].Trim()
        })
    }

    return $channels
}

function Receive-FinishedJobs {
    param([System.Collections.ArrayList]$Jobs)

    $finished = @($Jobs | Where-Object { $_.State -ne "Running" })
    foreach ($job in $finished) {
        Receive-Job -Job $job
        Remove-Job -Job $job -Force
        [void]$Jobs.Remove($job)
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

Write-Host "Verification des chaines TURKTV..." -ForegroundColor Cyan
Write-Host ("Chaines a tester: {0}" -f $channels.Count)
Write-Host "Cette verification teste les liens depuis ce PC. Un boitier IPTV peut parfois reagir differemment."
Write-Host ""

$jobs = New-Object System.Collections.ArrayList
$results = New-Object System.Collections.Generic.List[object]

$testScript = {
    param($Number, $Name, $Group, $Url, $TimeoutMs)

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {}

    $status = ""
    $contentType = ""
    $message = ""
    $ok = $false

    try {
        if ($Url -notmatch '^https?://') {
            throw "URL invalide"
        }

        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = "GET"
        $request.Timeout = $TimeoutMs
        $request.ReadWriteTimeout = $TimeoutMs
        $request.AllowAutoRedirect = $true
        $request.UserAgent = "VLC/3.0.18 LibVLC/3.0.18"
        try { $request.Headers.Add("Range", "bytes=0-4095") } catch {}

        $response = $request.GetResponse()
        $status = [int]$response.StatusCode
        $contentType = [string]$response.ContentType

        $stream = $response.GetResponseStream()
        $buffer = New-Object byte[] 4096
        $read = $stream.Read($buffer, 0, $buffer.Length)
        $bodyStart = ""
        if ($read -gt 0) {
            $bodyStart = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        }
        $response.Close()

        if ($status -ge 200 -and $status -lt 400) {
            if ($Url -match '\.m3u8(\?|$)' -or $contentType -match 'mpegurl|application/vnd.apple|application/x-mpegURL|audio/mpegurl' -or $bodyStart -match '#EXTM3U|#EXT-X-') {
                $ok = $true
                $message = "OK"
            } else {
                $message = "Reponse recue mais ce n'est pas une playlist HLS claire"
            }
        } else {
            $message = "HTTP $status"
        }
    } catch {
        $message = $_.Exception.Message
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $status = [int]$_.Exception.Response.StatusCode
        }
    }

    [pscustomobject]@{
        Number = $Number
        Name = $Name
        Group = $Group
        Url = $Url
        Ok = $ok
        Status = $status
        ContentType = $contentType
        Message = $message
    }
}

foreach ($channel in $channels) {
    while ((@($jobs | Where-Object { $_.State -eq "Running" }).Count) -ge $Parallel) {
        $done = Wait-Job -Job $jobs -Any -Timeout 2
        if ($done) {
            $received = Receive-FinishedJobs -Jobs $jobs
            foreach ($item in $received) { $results.Add($item) }
        }
    }

    $job = Start-Job -ScriptBlock $testScript -ArgumentList $channel.Number, $channel.Name, $channel.Group, $channel.Url, $TimeoutMs
    [void]$jobs.Add($job)
}

while ($jobs.Count -gt 0) {
    $done = Wait-Job -Job $jobs -Any -Timeout 2
    if ($done) {
        $received = Receive-FinishedJobs -Jobs $jobs
        foreach ($item in $received) { $results.Add($item) }
    }
}

$ordered = @($results | Sort-Object Number)
$broken = @($ordered | Where-Object { -not $_.Ok })

$ordered | Export-Csv -LiteralPath $ReportCsv -NoTypeInformation -Encoding UTF8

$text = New-Object System.Collections.Generic.List[string]
$text.Add("Chaines a corriger - TURKTV")
$text.Add(("Date: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")))
$text.Add(("Total teste: {0}" -f $ordered.Count))
$text.Add(("OK: {0}" -f (($ordered | Where-Object { $_.Ok }).Count)))
$text.Add(("A corriger: {0}" -f $broken.Count))
$text.Add("")
foreach ($item in $broken) {
    $text.Add(("{0}. {1}" -f $item.Number, $item.Name))
    if (-not [string]::IsNullOrWhiteSpace($item.Group)) { $text.Add(("   Groupe: {0}" -f $item.Group)) }
    $text.Add(("   Lien: {0}" -f $item.Url))
    $text.Add(("   Probleme: {0}" -f $item.Message))
    $text.Add("")
}
[System.IO.File]::WriteAllLines($ReportTxt, $text, [System.Text.Encoding]::UTF8)

Write-Host ""
Write-Host ("OK: {0}" -f (($ordered | Where-Object { $_.Ok }).Count)) -ForegroundColor Green
Write-Host ("A corriger: {0}" -f $broken.Count) -ForegroundColor Yellow
Write-Host ("Rapport simple: {0}" -f $ReportTxt)
Write-Host ("Rapport complet CSV: {0}" -f $ReportCsv)
