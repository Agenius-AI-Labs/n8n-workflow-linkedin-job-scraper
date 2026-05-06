# sync-workflows.ps1
# Reconcile disk JSON <-> live n8n-dev workflows for the LinkedIn job-scraper set.
#
# Modes:
#   pull   (default) - fetch live workflows by name, save as <file>-LIVE.json, print diff summary
#   align            - rewrite the disk file's id to match the live workflow's id (1:1 mapping)
#   push             - PUT disk file's nodes+connections+settings to the live workflow id (live id stays, content replaced)
#
# Reads N8N API key from prototypes/n8n-agent/.env (N8N_AGENT_API_KEY).
# Targets http://10.10.0.80:5679 (n8n-dev).

[CmdletBinding()]
param(
    [ValidateSet('pull','align','push')]
    [string]$Mode = 'pull',

    [string]$Base = 'http://10.10.0.80:5679',

    [string]$EnvFile = 'M:\Code\Agenius-AI-Labs\prototypes\n8n-agent\.env',

    [string]$Dir = 'M:\Code\Agenius-AI-Labs\automations\n8n-workflows\n8n-workflow-linkedin-job-scraper',

    # Restrict actions to a single disk filename (without path). Empty = all workflow*.json.
    [string]$Only = ''
)

$ErrorActionPreference = 'Stop'

function Get-EnvVar {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path $Path)) { throw "Env file not found: $Path" }
    $line = Select-String -Path $Path -Pattern "^$Key=" -SimpleMatch:$false | Select-Object -First 1
    if (-not $line) { throw "$Key not in $Path" }
    return ($line.Line -split '=', 2)[1].Trim()
}

$apiKey = Get-EnvVar -Path $EnvFile -Key 'N8N_AGENT_API_KEY'
$headers = @{ 'X-N8N-API-KEY' = $apiKey; 'Accept' = 'application/json' }

# Pull live workflow list once (paginated).
function Get-AllLiveWorkflows {
    $all = @()
    $cursor = $null
    do {
        $url = "$Base/api/v1/workflows?limit=250"
        if ($cursor) { $url += "&cursor=$cursor" }
        $resp = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
        $all += $resp.data
        $cursor = $resp.nextCursor
    } while ($cursor)
    return $all
}

Write-Host "Fetching live workflows from $Base..." -ForegroundColor Cyan
$live = Get-AllLiveWorkflows
Write-Host ("  {0} live workflows" -f $live.Count)

$pattern = if ($Only) { $Only } else { 'workflow*.json' }
$diskFiles = Get-ChildItem -Path $Dir -Filter $pattern -File |
    Where-Object { $_.Name -notlike '*-LIVE.json' }

if (-not $diskFiles) { Write-Host "No disk workflow files matched." -ForegroundColor Yellow; exit 0 }

$report = @()

foreach ($f in $diskFiles) {
    $disk = Get-Content $f.FullName -Raw | ConvertFrom-Json
    $diskName = $disk.name
    $diskId   = $disk.id

    $liveMatch = $live | Where-Object { $_.name -eq $diskName }
    $liveCount = @($liveMatch).Count

    $row = [pscustomobject]@{
        File       = $f.Name
        Name       = $diskName
        DiskId     = $diskId
        LiveId     = ($liveMatch | Select-Object -First 1).id
        LiveCount  = $liveCount
        Status     = ''
        Action     = ''
    }

    if ($liveCount -eq 0) {
        $row.Status = 'NO LIVE MATCH'
    } elseif ($liveCount -gt 1) {
        $row.Status = "MULTIPLE LIVE ($liveCount)"
    } elseif ($row.LiveId -eq $diskId) {
        $row.Status = 'IN SYNC'
    } else {
        $row.Status = 'ID MISMATCH'
    }

    switch ($Mode) {
        'pull' {
            if ($liveCount -ge 1) {
                $liveId = ($liveMatch | Select-Object -First 1).id
                $detail = Invoke-RestMethod -Uri "$Base/api/v1/workflows/$liveId" -Headers $headers -Method Get
                $outPath = Join-Path $Dir ([IO.Path]::GetFileNameWithoutExtension($f.Name) + '-LIVE.json')
                $detail | ConvertTo-Json -Depth 100 | Set-Content -Path $outPath -Encoding UTF8
                $row.Action = "saved $([IO.Path]::GetFileName($outPath))"
            } else {
                $row.Action = 'skip (no live)'
            }
        }
        'align' {
            if ($liveCount -eq 1 -and $row.LiveId -ne $diskId) {
                $disk.id = $row.LiveId
                $disk | ConvertTo-Json -Depth 100 | Set-Content -Path $f.FullName -Encoding UTF8
                $row.Action = "disk id -> $($row.LiveId)"
            } else {
                $row.Action = 'skip'
            }
        }
        'push' {
            if ($liveCount -eq 1) {
                $liveId = $row.LiveId
                $body = [ordered]@{
                    name        = $disk.name
                    nodes       = $disk.nodes
                    connections = $disk.connections
                    settings    = $disk.settings
                    staticData  = $disk.staticData
                } | ConvertTo-Json -Depth 100 -Compress
                Invoke-RestMethod -Uri "$Base/api/v1/workflows/$liveId" -Headers $headers -Method Put -ContentType 'application/json' -Body $body | Out-Null
                $row.Action = "pushed to $liveId"
            } else {
                $row.Action = 'skip (need exactly 1 live match)'
            }
        }
    }

    $report += $row
}

$report | Format-Table File, Name, Status, DiskId, LiveId, Action -AutoSize
