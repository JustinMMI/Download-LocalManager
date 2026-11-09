Add-Type -AssemblyName System.Windows.Forms
$scriptDir = $PSScriptRoot
$config = Get-Content (Join-Path $scriptDir "config.json") -Encoding UTF8 | ConvertFrom-Json
$lastPathFile = Join-Path $scriptDir "last_path.txt"
$logFile = Join-Path $scriptDir "Chromium_Master.log"
$processedFile = Join-Path $scriptDir "processed_downloads.txt"

$tempBrave = $config.dossier_temp_brave
$mainDownloads = $config.dossier_telechargements_classique
$processedFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
if (Test-Path -LiteralPath $processedFile) {
    Get-Content -LiteralPath $processedFile -Encoding UTF8 |
        Where-Object { $_ } |
        ForEach-Object { [void]$processedFiles.Add($_) }
}

if (-not (Test-Path $tempBrave)) { New-Item -ItemType Directory -Path $tempBrave -Force | Out-Null }

function Write-RouteLog {
    param([string]$Message)
    Add-Content -LiteralPath $logFile -Encoding UTF8 -Value "$(Get-Date -Format s) $Message"
}

function Compact-ProcessedState {
    $latestByPath = @{}
    foreach ($entry in $processedFiles) {
        $separator = $entry.IndexOf("|")
        $path = if ($separator -lt 1) { $entry } else { $entry.Substring(0, $separator) }
        if (Test-Path -LiteralPath $path) {
            $current = Get-Item -LiteralPath $path -Force
            $latestByPath[$path] = "{0}|{1}" -f $path, $current.CreationTimeUtc.Ticks
        }
    }

    $processedFiles.Clear()
    foreach ($entry in $latestByPath.Values) {
        [void]$processedFiles.Add($entry)
    }
    Set-Content -LiteralPath $processedFile -Encoding UTF8 -Value @($latestByPath.Values)
}

function Mark-FileProcessed {
    param([System.IO.FileInfo]$File)
    $current = Get-Item -LiteralPath $File.FullName -Force
    $entry = "{0}|{1}" -f $current.FullName, $current.CreationTimeUtc.Ticks
    if ($processedFiles.Add($entry)) {
        Add-Content -LiteralPath $processedFile -Encoding UTF8 -Value $entry
        Compact-ProcessedState
    }
}

function Remove-FileProcessed {
    param([System.IO.FileInfo]$File)
    $entry = "{0}|{1}" -f $File.FullName, $File.CreationTimeUtc.Ticks
    if ($processedFiles.Remove($entry)) {
        Set-Content -LiteralPath $processedFile -Encoding UTF8 -Value @($processedFiles)
    }
}

function Test-FileProcessed {
    param([System.IO.FileInfo]$File)
    $prefix = "{0}|" -f $File.FullName
    return @($processedFiles | Where-Object { $_ -like "$prefix*" }).Count -gt 0
}

Compact-ProcessedState

function Show-DownloadSaveDialog {
    param([System.Windows.Forms.SaveFileDialog]$Dialog)

    $owner = New-Object System.Windows.Forms.Form
    $owner.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $owner.ShowInTaskbar = $false
    $owner.ShowIcon = $false
    $owner.TopMost = $true
    $owner.Opacity = 0
    $owner.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $owner.Size = New-Object System.Drawing.Size(1, 1)
    $owner.Location = New-Object System.Drawing.Point(
        ([System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Right - 1),
        ([System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Bottom - 1)
    )
    $owner.Show()
    $owner.Activate()
    $result = $Dialog.ShowDialog($owner)
    $owner.Close()
    $owner.Dispose()
    return $result
}

function Test-FileReady {
    param([System.IO.FileInfo]$File)
    try {
        $stream = [System.IO.File]::Open($File.FullName, 'Open', 'Read', 'None')
        $stream.Dispose()
        return $true
    }
    catch {
        return $false
    }
}

function Get-DownloadOrigin {
    param([System.IO.FileInfo]$File)
    $zone = Get-Content -LiteralPath $File.FullName -Stream Zone.Identifier -Raw -ErrorAction Stop
    return ($zone -replace "`0", "")
}

function Get-RoutingRule {
    param([System.IO.FileInfo]$File)
    $origin = Get-DownloadOrigin $File
    foreach ($rule in $config.regles_routage) {
        if (($origin -match "HostUrl=$($rule.url_source)") -or
            ($origin -match "ReferrerUrl=$($rule.url_source)")) {
            return $rule
        }
    }
    return $null
}

function New-BraveLink {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )
    $sourceDrive = (Split-Path $SourcePath -Qualifier).ToUpperInvariant()
    $destinationDrive = (Split-Path $DestinationPath -Qualifier).ToUpperInvariant()
    if ($sourceDrive -ne $destinationDrive) {
        return $false
    }

    if (Test-Path -LiteralPath $DestinationPath) {
        throw "La destination existe déjà: $DestinationPath"
    }
    $result = & cmd.exe /c "mklink /H `"$DestinationPath`" `"$SourcePath`"" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Création du lien impossible: $($result -join ' ')"
    }
    return $true
}

function Get-UniqueDestinationPath {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $Path
    }

    $directory = Split-Path -Parent $Path
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $extension = [System.IO.Path]::GetExtension($Path)
    $index = 1
    do {
        $candidate = Join-Path $directory "$baseName ($index)$extension"
        $index++
    } while (Test-Path -LiteralPath $candidate)
    return $candidate
}

function New-BraveSymbolicLink {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )
    if (Test-Path -LiteralPath $SourcePath) {
        Remove-Item -LiteralPath $SourcePath -Force -ErrorAction Stop
    }
    $result = & cmd.exe /c "mklink `"$SourcePath`" `"$DestinationPath`"" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Création du lien symbolique impossible: $($result -join ' ')"
    }
}

function Test-RoutedFile {
    param([System.IO.FileInfo]$File)
    if ($File.LinkType -eq "SymbolicLink") {
        return $true
    }
    return Test-FileProcessed $File
}

function New-PersistentBraveLink {
    param(
        [System.IO.FileInfo]$File,
        [string]$DestinationPath
    )
    $sourcePath = [System.IO.Path]::GetFullPath($File.FullName)
    $destinationPath = [System.IO.Path]::GetFullPath($DestinationPath)
    if ($sourcePath -eq $destinationPath) {
        return
    }

    $sourceDrive = (Split-Path $sourcePath -Qualifier).ToUpperInvariant()
    $destinationDrive = (Split-Path $destinationPath -Qualifier).ToUpperInvariant()
    if ($sourceDrive -eq $destinationDrive) {
        if (Test-Path -LiteralPath $destinationPath) {
            Remove-Item -LiteralPath $destinationPath -Force -ErrorAction Stop
        }
        New-BraveLink -SourcePath $sourcePath -DestinationPath $destinationPath | Out-Null
        return
    }

    if (Test-Path -LiteralPath $destinationPath) {
        Remove-Item -LiteralPath $destinationPath -Force -ErrorAction Stop
    }
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force -ErrorAction Stop
    try {
        New-BraveSymbolicLink -SourcePath $sourcePath -DestinationPath $destinationPath
    }
    catch {
        Copy-Item -LiteralPath $destinationPath -Destination $sourcePath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Move-RoutedFile {
    param(
        [System.IO.FileInfo]$File,
        [string]$DestinationFolder
    )
    if (-not (Test-Path -LiteralPath $DestinationFolder)) {
        New-Item -ItemType Directory -LiteralPath $DestinationFolder -Force -ErrorAction Stop | Out-Null
    }

    $destinationPath = Get-UniqueDestinationPath (Join-Path $DestinationFolder $File.Name)
    if (New-BraveLink -SourcePath $File.FullName -DestinationPath $destinationPath) {
        return $destinationPath
    }

    Move-Item -LiteralPath $File.FullName -Destination $destinationPath -Force -ErrorAction Stop
    return $destinationPath
}

while ($true) {
    $oldFiles = Get-ChildItem -LiteralPath $tempBrave -File |
        Where-Object { $_.CreationTime -lt (Get-Date).AddHours(-12) }
    foreach ($old in $oldFiles) {
        if (Test-FileProcessed $old) {
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $old.FullName)) {
                Remove-FileProcessed -File $old
            }
        }
    }

    $files = Get-ChildItem -LiteralPath $tempBrave -File |
        Where-Object {
            $_.Extension -notmatch "\.crdownload$|\.tmp$" -and
            -not (Test-RoutedFile $_)
        }

    $routedFiles = foreach ($file in $files) {
        if (-not (Test-FileReady $file)) { continue }
        try {
            $rule = Get-RoutingRule $file
            if ($null -ne $rule) {
                $finalPath = Move-RoutedFile -File $file -DestinationFolder $rule.dossier_destination
                Mark-FileProcessed -File $file
                Write-RouteLog "Routé: $($file.Name) -> $finalPath"
                [PSCustomObject]@{ File = $file; FinalPath = $finalPath }
            }
        }
        catch {
            Write-RouteLog "Échec du routage de $($file.Name): $($_.Exception.Message)"
        }
    }

    foreach ($item in $routedFiles) {
        $files = $files | Where-Object { $_.FullName -ne $item.File.FullName }
    }

    foreach ($file in $files) {
        if (-not (Test-FileReady $file)) { continue }
        try {
            $dialog = New-Object System.Windows.Forms.SaveFileDialog
            $dialog.FileName = $file.Name
            $dialog.Title = "Enregistrer sous"
            $dialog.Filter = "Tous les fichiers (*.*)|*.*"
            
            if (Test-Path -LiteralPath $lastPathFile) { $dialog.InitialDirectory = Get-Content -LiteralPath $lastPathFile }
            else { $dialog.InitialDirectory = $mainDownloads }
            
            Write-RouteLog "Ouverture de la fenêtre pour $($file.Name)"
            $result = Show-DownloadSaveDialog -Dialog $dialog
            Write-RouteLog "Résultat de la fenêtre pour $($file.Name): $result"
            
            if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
                $finalPath = $dialog.FileName
                if (-not (Test-Path -LiteralPath $file.FullName)) {
                    throw "Le fichier n'est plus présent dans le sas."
                }
                New-PersistentBraveLink -File $file -DestinationPath $finalPath
                Mark-FileProcessed -File $file
                Set-Content -LiteralPath $lastPathFile -Value (Split-Path $finalPath) -ErrorAction Stop
            }
            else {
                $finalPath = Join-Path $mainDownloads $file.Name
                if (-not (Test-Path -LiteralPath $file.FullName)) {
                    throw "Le fichier n'est plus présent dans le sas."
                }
                New-PersistentBraveLink -File $file -DestinationPath $finalPath
                Mark-FileProcessed -File $file
            }
            $dialog.Dispose()
            Write-RouteLog "Déplacement manuel: $($file.Name) -> $finalPath"
        }
        catch {
            Write-RouteLog "Échec du déplacement de $($file.Name): $($_.Exception.Message)"
        }
    }
    Start-Sleep -Seconds 2
}