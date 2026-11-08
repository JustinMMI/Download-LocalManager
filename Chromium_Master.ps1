Add-Type -AssemblyName System.Windows.Forms
$scriptDir = $PSScriptRoot
$config = Get-Content (Join-Path $scriptDir "config.json") | ConvertFrom-Json
$lastPathFile = Join-Path $scriptDir "last_path.txt"

$tempBrave = $config.dossier_temp_brave
$mainDownloads = $config.dossier_telechargements_classique

if (-not (Test-Path $tempBrave)) { New-Item -ItemType Directory -Path $tempBrave -Force | Out-Null }

while ($true) {
    # 1. Nettoyage des fantômes (liens physiques) de plus de 12 heures
    $oldFiles = Get-ChildItem -Path $tempBrave -File | Where-Object { $_.CreationTime -lt (Get-Date).AddHours(-12) }
    foreach ($old in $oldFiles) {
        # On supprime uniquement si c'est un de nos fantômes marqués
        if (Get-Item -Path $old.FullName -Stream "BraveRouted" -ErrorAction SilentlyContinue) {
            Remove-Item -Path $old.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    # 2. Scan des nouveaux téléchargements
    $files = Get-ChildItem -Path $tempBrave -File | Where-Object { $_.Extension -notmatch "\.crdownload$|\.tmp$" }
    
    foreach ($file in $files) {
        # Ignorer la boucle si c'est un fantôme qu'on a déjà traité
        if (Get-Item -Path $file.FullName -Stream "BraveRouted" -ErrorAction SilentlyContinue) {
            continue
        }

        Start-Sleep -Milliseconds 400
        $estRoute = $false
        $finalPath = ""
        
        try {
            $zone = Get-Content -Path $file.FullName -Stream Zone.Identifier -ErrorAction Stop
            
            foreach ($regle in $config.regles_routage) {
                if (($zone -match "HostUrl=$($regle.url_source)") -or ($zone -match "ReferrerUrl=$($regle.url_source)")) {
                    $destFolder = $regle.dossier_destination
                    if (-not (Test-Path $destFolder)) { New-Item -ItemType Directory -Path $destFolder -Force | Out-Null }
                    
                    $finalPath = Join-Path $destFolder $file.Name
                    Move-Item -Path $file.FullName -Destination $finalPath -Force
                    $estRoute = $true
                    break
                }
            }
        }
        catch { }

        # Pas de règle -> Fenêtre native Windows
        if (-not $estRoute) {
            $dialog = New-Object System.Windows.Forms.SaveFileDialog
            $dialog.FileName = $file.Name
            $dialog.Title = "Enregistrer sous"
            $dialog.Filter = "Tous les fichiers (*.*)|*.*"
            
            if (Test-Path $lastPathFile) { $dialog.InitialDirectory = Get-Content $lastPathFile } 
            else { $dialog.InitialDirectory = $mainDownloads }
            
            $form = New-Object System.Windows.Forms.Form
            $form.TopMost = $true
            $result = $dialog.ShowDialog($form)
            
            if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
                $finalPath = $dialog.FileName
                Move-Item -Path $file.FullName -Destination $finalPath -Force
                Set-Content -Path $lastPathFile -Value (Split-Path $finalPath)
            }
            else {
                # Si annulé, ça part dans Téléchargements normal
                $finalPath = Join-Path $mainDownloads $file.Name
                Move-Item -Path $file.FullName -Destination $finalPath -Force
            }
            $form.Dispose()
            $dialog.Dispose()
        }
        
        # 3. La magie : Création du fantôme pour Brave
        if (Test-Path $finalPath) {
            $driveSource = Split-Path $tempBrave -Qualifier
            $driveDest = Split-Path $finalPath -Qualifier
            
            # Les Hardlinks ne fonctionnent que si la source et la cible sont sur le même disque (ex: C:)
            if ($driveSource -eq $driveDest) {
                cmd /c mklink /H "`"$($file.FullName)`"" "`"$finalPath`"" | Out-Null
                
                # On marque le fichier avec un flux caché pour que la boucle l'ignore
                Set-Content -Path $file.FullName -Stream "BraveRouted" -Value "1" -ErrorAction SilentlyContinue
            }
        }
    }
    Start-Sleep -Seconds 2
}