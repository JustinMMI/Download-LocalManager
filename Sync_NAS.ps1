$scriptDir = $PSScriptRoot
$config = Get-Content (Join-Path $scriptDir "config.json") | ConvertFrom-Json

$bufferNas = $config.dossier_tampon_nas
$nasDest = $config.destination_nas

while ($true) {
    if (Test-Path $nasDest) {
        $files = Get-ChildItem -Path $bufferNas -File | Where-Object { $_.Extension -notmatch "\.crdownload$|\.tmp$" }
        
        foreach ($file in $files) {
            try {
                Move-Item -Path $file.FullName -Destination $nasDest -Force -ErrorAction Stop
            } catch {}
        }
    }
    Start-Sleep -Seconds 30
}