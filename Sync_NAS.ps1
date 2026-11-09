$scriptDir = $PSScriptRoot
$config = Get-Content (Join-Path $scriptDir "config.json") -Encoding UTF8 | ConvertFrom-Json

$bufferNas = $config.dossier_tampon_nas
$nasDest = $config.destination_nas
$logFile = Join-Path $scriptDir "Sync_NAS.log"

if (-not (Test-Path -LiteralPath $bufferNas)) {
    New-Item -ItemType Directory -Path $bufferNas -Force | Out-Null
}

function Get-UniqueDestinationPath {
    param([string]$Directory, [string]$Name)
    $path = Join-Path $Directory $Name
    if (-not (Test-Path -LiteralPath $path)) {
        return $path
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $extension = [System.IO.Path]::GetExtension($Name)
    $index = 1
    do {
        $candidate = Join-Path $Directory "$baseName ($index)$extension"
        $index++
    } while (Test-Path -LiteralPath $candidate)
    return $candidate
}

while ($true) {
    if (-not (Test-Path -LiteralPath $nasDest)) {
        Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format s) Destination NAS inaccessible: $nasDest"
        Start-Sleep -Seconds 30
        continue
    }

    $files = Get-ChildItem -LiteralPath $bufferNas -File |
        Where-Object { $_.Extension -notmatch "\.crdownload$|\.tmp$" }

    foreach ($file in $files) {
        try {
            $destinationPath = Get-UniqueDestinationPath -Directory $nasDest -Name $file.Name
            Move-Item -LiteralPath $file.FullName -Destination $destinationPath -ErrorAction Stop
            Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format s) Transféré: $($file.Name) -> $destinationPath"
        }
        catch {
            Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format s) Échec pour $($file.Name): $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 30
}