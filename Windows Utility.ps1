# =========================
# PARAMETERS
# =========================
param(
    [switch]$Relaunched
)

# =========================
# SELF-RELAUNCH FOR "RUN WITH POWERSHELL"
# =========================
if (-not $Relaunched -and $PSCommandPath) {
    $argString = '-NoLogo -NoExit -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Relaunched'
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argString
    exit
}

$Host.UI.RawUI.WindowTitle = "Windows Config Tool"

# =========================
# GLOBAL STATE
# =========================
$CurrentPage = "Main"
$Breadcrumb = @("Main Menu")
$LastError = $null
$Running = $true
$SelectedQOLKey = $null
$SelectedShortcutKey = $null

$RegistryQOLNames = @{
    '1' = "Windows Ads & Suggestions"
    '2' = "Lock Screen Spotlight"
    '3' = "Long File Paths"
    '4' = "Game Bar"
    '5' = "Startup Delay"
    '6' = "Verbose Boot Messages"
    '7' = "Telemetry"
}

$RegistryShortcutNames = @{
    '1' = "Take Ownership to Context Menu"
    '2' = "Open PowerShell Here"
    '3' = "Restart Explorer Shortcut"
    '4' = "Clear Clipboard Shortcut"
    '5' = "Safe Mode Boot Option"
}

# =========================
# UI HELPERS
# =========================
function Read-SingleKey {
    while ($true) {
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

        if ($key.VirtualKeyCode -ge 48 -and $key.VirtualKeyCode -le 57) {
            return [string]([char]$key.VirtualKeyCode)
        }

        if ($key.VirtualKeyCode -ge 96 -and $key.VirtualKeyCode -le 105) {
            return [string]($key.VirtualKeyCode - 96)
        }
    }
}



function Wait-AnyKey {
    Write-Host ""
    Write-Host "Press any key to return..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Show-Header {
    Clear-Host
    Write-Host "==============================================" -ForegroundColor DarkCyan
    Write-Host (" " + ($Breadcrumb -join "  >  ")) -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor DarkCyan
    if ($LastError) {
        $err = $LastError
        $LastError = $null
        Write-Host "ERROR: $err" -ForegroundColor Red
        Write-Host ""
    }
}

function Show-ActionResult {
    param (
        [string]$ActionName,
        [bool]$Success = $true
    )

    Clear-Host
    Write-Host "==============================================" -ForegroundColor DarkCyan
    if ($Success) {
        Write-Host "SUCCESS: $ActionName completed." -ForegroundColor Green
    }
    else {
        Write-Host "FAILED: $ActionName did not complete." -ForegroundColor Red
    }
    Write-Host "==============================================" -ForegroundColor DarkCyan
    Wait-AnyKey
}

function Read-ValidatedNumber {
    param (
        [string]$Prompt,
        [int]$Min,
        [int]$Max
    )

    while ($true) {
        Write-Host ""
        Write-Host $Prompt -ForegroundColor Yellow
        $userInput = Read-Host

        if ([string]::IsNullOrWhiteSpace($userInput)) {
            Write-Host "Invalid input: empty or whitespace." -ForegroundColor Red
            continue
        }

        if ($userInput -notmatch '^\d+$') {
            Write-Host "Invalid input: numbers only." -ForegroundColor Red
            continue
        }

        $value = [int]$userInput
        if ($value -lt $Min -or $value -gt $Max) {
            Write-Host "Value must be between $Min and $Max." -ForegroundColor Red
            continue
        }

        return $value
    }
}

function Uninstall-WindowsApp {
    param([string]$AppName)

    $patterns = @(
        "*$AppName*",
        "*$($AppName -replace ' ', '')*"
    )

    $removedSomething = $false
    $protectedApps = @()

    foreach ($pattern in $patterns) {

        # Remove for current user only
        $pkgs = Get-AppxPackage | Where-Object { $_.Name -like $pattern -or $_.PackageFullName -like $pattern }

        foreach ($pkg in $pkgs) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                $removedSomething = $true
            }
            catch {
                $protectedApps += $pkg.Name
            }
        }

        # Remove provisioned package (for new users)
        $provPkgs = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like $pattern }

        foreach ($prov in $provPkgs) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
                $removedSomething = $true
            }
            catch {
                $protectedApps += $prov.DisplayName
            }
        }
    }

    return @{ Success = $removedSomething; Protected = $protectedApps }
}

function Test-IsAdmin {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-SystemRestorePointElevated {
    $resultFile = Join-Path $env:TEMP "WinUtil_RestorePointResult_$([guid]::NewGuid().ToString('N')).json"

    $elevatedCommand = @"
try {
    Checkpoint-Computer -Description 'Windows Utility Restore Point' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
    @{ Success = `$true; Error = `$null } | ConvertTo-Json | Set-Content -Path '$resultFile' -Encoding UTF8
}
catch {
    @{ Success = `$false; Error = `$_.Exception.Message } | ConvertTo-Json | Set-Content -Path '$resultFile' -Encoding UTF8
}
"@

    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($elevatedCommand))

    try {
        $proc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encodedCommand" `
            -Verb RunAs -PassThru -ErrorAction Stop
    }
    catch {
        # Most commonly hit when the user clicks "No" on the UAC prompt
        return @{ Success = $false; Error = "Elevation was cancelled or failed: $($_.Exception.Message)" }
    }

    $percent = 0
    while (-not $proc.HasExited) {
        $percent = [Math]::Min($percent + 5, 90)
        Write-Progress -Activity "Creating System Restore Point" -Status "This can take a minute or two, please wait..." -PercentComplete $percent
        Start-Sleep -Milliseconds 500
    }

    Write-Progress -Activity "Creating System Restore Point" -Status "Finalizing..." -PercentComplete 100
    Start-Sleep -Milliseconds 300
    Write-Progress -Activity "Creating System Restore Point" -Completed

    if (Test-Path $resultFile) {
        $resultJson = Get-Content -Path $resultFile -Raw | ConvertFrom-Json
        Remove-Item -Path $resultFile -Force -ErrorAction SilentlyContinue
        return @{ Success = $resultJson.Success; Error = $resultJson.Error }
    }

    return @{ Success = $false; Error = "Elevated process did not return a result (exit code $($proc.ExitCode))." }
}

function New-SystemRestorePoint {
    Clear-Host
    Write-Host "==============================================" -ForegroundColor DarkCyan
    Write-Host " Creating System Restore Point" -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor DarkCyan
    Write-Host ""

    if (-not (Test-IsAdmin)) {
        Write-Host "Administrator privileges are required for this action." -ForegroundColor Yellow
        Write-Host "Requesting elevation - accept the UAC prompt to continue..." -ForegroundColor Yellow
        Write-Host ""
        return New-SystemRestorePointElevated
    }

    $job = Start-Job -ScriptBlock {
        Checkpoint-Computer -Description "Windows Utility Restore Point" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
    }

    $percent = 0
    while ($job.State -eq 'Running') {
        $percent = [Math]::Min($percent + 5, 90)
        Write-Progress -Activity "Creating System Restore Point" -Status "This can take a minute or two, please wait..." -PercentComplete $percent
        Start-Sleep -Milliseconds 500
    }

    Write-Progress -Activity "Creating System Restore Point" -Status "Finalizing..." -PercentComplete 100
    Start-Sleep -Milliseconds 300
    Write-Progress -Activity "Creating System Restore Point" -Completed

    $errorMessage = $null
    try {
        Receive-Job -Job $job -ErrorAction Stop | Out-Null
    }
    catch {
        $errorMessage = $_.Exception.Message
    }
    Remove-Job -Job $job -Force

    return @{ Success = [string]::IsNullOrEmpty($errorMessage); Error = $errorMessage }
}


# =========================
# PAGE RENDERERS
# =========================
function Show-MainMenu {
    Show-Header
    Write-Host "Select any of the below options to begin.`n"
    Write-Host "[1] Registry QOL Changes" -ForegroundColor Green
    Write-Host "[2] Registry Shortcuts" -ForegroundColor Green
    Write-Host "[3] Windows Password Configuration" -ForegroundColor Green
    Write-Host "[4] Uninstall Windows Program" -ForegroundColor Green
    Write-Host "[5] Create System Restore Point" -ForegroundColor Green
    Write-Host "[0] Exit" -ForegroundColor DarkRed
}

function Show-RegistryQOL {
    Show-Header
    Write-Host "[1] Toggle Windows Ads & Suggestions"
    Write-Host "[2] Toggle Lock Screen Spotlight"
    Write-Host "[3] Toggle Long File Paths"
    Write-Host "[4] Toggle Game Bar"
    Write-Host "[5] Toggle Startup Delay"
    Write-Host "[6] Toggle Verbose Boot Messages"
    Write-Host "[7] Toggle Telemetry"
    Write-Host "[0] Return"
}

function Show-RegistryQOLToggle {
    Show-Header
    Write-Host "[1] Enable"
    Write-Host "[2] Disable"
    Write-Host "[0] Return"
}

function Show-RegistryShortcuts {
    Show-Header
    Write-Host "[1] Toggle Take Ownership to Context Menu"
    Write-Host "[2] Toggle Open PowerShell Here"
    Write-Host "[3] Toggle Restart Explorer Shortcut"
    Write-Host "[4] Toggle Clear Clipboard Shortcut"
    Write-Host "[5] Toggle Safe Mode Boot Option"
    Write-Host "[0] Return"
}

function Show-RegistryShortcutToggle {
    Show-Header
    Write-Host "[1] Add"
    Write-Host "[2] Remove"
    Write-Host "[0] Return"
}

function Show-PasswordMenu {
    Show-Header
    Write-Host "Windows Password Configuration`n"
    Write-Host "[1] Change minimum password age (days)"
    Write-Host "[2] Change maximum password age (days)"
    Write-Host "[3] Change minimum password length"
    Write-Host "[4] Change lockout threshold"
    Write-Host "[5] Change lockout duration (minutes)"
    Write-Host "[0] Return"
}

function Show-UninstallProgramMenu {
    Show-Header
    Write-Host "Uninstall Windows Program`n"
    Write-Host "Enter the name of a built-in Windows app to remove."
    Write-Host "Examples: Get Help, Get Started, Game Bar, Xbox, People, Windows Backup"
    Write-Host ""
    Write-Host "[0] Return"
}

function Show-SystemRestoreMenu {
    Show-Header
    Write-Host "Creates a Windows System Restore Point using the built-in System`n"
    Write-Host "Restore feature. Requires Administrator privileges and System`n"
    Write-Host "Restore to be enabled on the system drive.`n"
    Write-Host "[1] Create Restore Point" -ForegroundColor Green
    Write-Host "[0] Return"
}

# =========================
# MAIN LOOP
# =========================
try {
    while ($Running) {

        switch ($CurrentPage) {

            # =========================
            # MAIN MENU
            # =========================
            "Main" {
                Show-MainMenu
                $choice = Read-SingleKey
                $choice = [string]$choice.Trim()
                switch ($choice) {
                    '1' { $LastError = $null; $CurrentPage = "RegistryQOL"; $Breadcrumb = @("Main Menu", "Registry QOL Changes") }
                    '2' { $LastError = $null; $CurrentPage = "RegistryShortcuts"; $Breadcrumb = @("Main Menu", "Registry Shortcuts") }
                    '3' { $LastError = $null; $CurrentPage = "Password"; $Breadcrumb = @("Main Menu", "Windows Password Configuration") }
                    '4' { $CurrentPage = "UninstallProgram"; $Breadcrumb = @("Main Menu", "Uninstall Windows Program") }
                    '5' { $LastError = $null; $CurrentPage = "SystemRestore"; $Breadcrumb = @("Main Menu", "Create System Restore Point") }
                    '0' { [Environment]::Exit(0) }
                    default { $LastError = "Invalid selection." }
                }
            }

            # =========================
            # REGISTRY QOL
            # =========================
            "RegistryQOL" {
                Show-RegistryQOL
                $choice = Read-SingleKey
                $choice = [string]$choice.Trim()

                if ($choice -eq '0') {
                    $LastError = $null
                    $CurrentPage = "Main"
                    $Breadcrumb = @("Main Menu")
                }
                elseif ($RegistryQOLNames.ContainsKey($choice)) {
                    $LastError = $null
                    $SelectedQOLKey = $choice
                    $CurrentPage = "RegistryQOLToggle"
                    $Breadcrumb = @("Main Menu", "Registry QOL Changes", $RegistryQOLNames[$choice])
                }
                else {
                    $LastError = "Invalid selection."
                }

            }


            # =========================
            # REGISTRY QOL TOGGLE
            # =========================
            "RegistryQOLToggle" {
                Show-RegistryQOLToggle
                $choice = Read-SingleKey
                $choice = [string]$choice.Trim()

                switch ($choice) {
                    '1' {
                        $LastError = $null
                        $name = "Enable $($RegistryQOLNames[$SelectedQOLKey])"
                        Show-ActionResult $name $true
                        $CurrentPage = "RegistryQOL"
                        $Breadcrumb = @("Main Menu", "Registry QOL Changes")
                    }
                    '2' {
                        $LastError = $null
                        $name = "Disable $($RegistryQOLNames[$SelectedQOLKey])"
                        Show-ActionResult $name $true
                        $CurrentPage = "RegistryQOL"
                        $Breadcrumb = @("Main Menu", "Registry QOL Changes")
                    }
                    '0' {
                        $LastError = $null
                        $CurrentPage = "RegistryQOL"
                        $Breadcrumb = @("Main Menu", "Registry QOL Changes")
                    }
                    default { $LastError = "Invalid selection." }
                }
            }


            # =========================
            # REGISTRY SHORTCUTS
            # =========================
            "RegistryShortcuts" {
                Show-RegistryShortcuts
                $choice = Read-SingleKey
                $choice = [string]$choice.Trim()

                if ($choice -eq '0') {
                    $LastError = $null
                    $CurrentPage = "Main"
                    $Breadcrumb = @("Main Menu")
                }
                elseif ($RegistryShortcutNames.ContainsKey($choice)) {
                    $LastError = $null
                    $SelectedShortcutKey = $choice
                    $CurrentPage = "RegistryShortcutToggle"
                    $Breadcrumb = @("Main Menu", "Registry Shortcuts", $RegistryShortcutNames[$choice])
                }
                else {
                    $LastError = "Invalid selection."
                }
            }


            # =========================
            # REGISTRY SHORTCUT TOGGLE
            # =========================
            "RegistryShortcutToggle" {
                Show-RegistryShortcutToggle
                $choice = Read-SingleKey
                $choice = [string]$choice.Trim()

                switch ($choice) {
                    '1' {
                        $LastError = $null
                        $name = "Add $($RegistryShortcutNames[$SelectedShortcutKey])"
                        Show-ActionResult $name $true
                        $CurrentPage = "RegistryShortcuts"
                        $Breadcrumb = @("Main Menu", "Registry Shortcuts")
                    }
                    '2' {
                        $LastError = $null
                        $name = "Remove $($RegistryShortcutNames[$SelectedShortcutKey])"
                        Show-ActionResult $name $true
                        $CurrentPage = "RegistryShortcuts"
                        $Breadcrumb = @("Main Menu", "Registry Shortcuts")
                    }
                    '0' {
                        $LastError = $null
                        $CurrentPage = "RegistryShortcuts"
                        $Breadcrumb = @("Main Menu", "Registry Shortcuts")
                    }
                    default { $LastError = "Invalid selection." }
                }
            }


            # =========================
            # PASSWORD CONFIG
            # =========================
            "Password" {
                Show-PasswordMenu
                $key = Read-SingleKey
                $key = [string]$key.Trim()
                $LastError = $null

                switch ($key) {
                    '1' { Clear-Host; $v = Read-ValidatedNumber "Enter minimum password age (days):" 0 365; Show-ActionResult "Change minimum password age to $v days" $true $LastError = $null }
                    '2' { Clear-Host; $v = Read-ValidatedNumber "Enter maximum password age (days):" 1 365; Show-ActionResult "Change maximum password age to $v days" $true $LastError = $null }
                    '3' { Clear-Host; $v = Read-ValidatedNumber "Enter minimum password length:" 1 128; Show-ActionResult "Change minimum password length to $v" $true $LastError = $null }
                    '4' { Clear-Host; $v = Read-ValidatedNumber "Enter lockout threshold:" 0 50; Show-ActionResult "Change lockout threshold to $v attempts" $true $LastError = $null }
                    '5' { Clear-Host; $v = Read-ValidatedNumber "Enter lockout duration (minutes):" 0 9999; Show-ActionResult "Change lockout duration to $v minutes" $true $LastError = $null }

                    '0' {
                        $LastError = $null
                        $CurrentPage = "Main"
                        $Breadcrumb = @("Main Menu")
                    }

                    default { $LastError = "Invalid selection." }
                }
            }

            # =========================
            # UNINSTALL PROGRAM
            # =========================
            "UninstallProgram" {
                Show-UninstallProgramMenu
                $appName = Read-Host "Program name (or 0 to return)"

                if ($appName -eq "0") {
                    $CurrentPage = "Main"
                    $Breadcrumb = @("Main Menu")
                }
                elseif ([string]::IsNullOrWhiteSpace($appName)) {
                    $LastError = "You must enter a program name."
                }
                else {
                    try {
                        $result = Uninstall-WindowsApp $appName

                        if ($result.Success -and $result.Protected.Count -gt 0) {
                            Show-ActionResult "Could not uninstall '$appName'. Protected system app(s): $($result.Protected -join ', ')" $false
                        }
                        elseif ($result.Success) {
                            Show-ActionResult "Uninstalled '$appName'" $true
                        }
                        else {
                            Show-ActionResult "'$appName' cannot be uninstalled (may be system-protected)" $false
                        }
                    }
                    catch {
                        Show-ActionResult "Failed to uninstall '$appName': $_" $false
                    }
                }
            }

            # =========================
            # SYSTEM RESTORE POINT
            # =========================
            "SystemRestore" {
                Show-SystemRestoreMenu
                $choice = Read-SingleKey
                $choice = [string]$choice.Trim()

                switch ($choice) {
                    '1' {
                        $LastError = $null
                        $result = New-SystemRestorePoint
                        if ($result.Success) {
                            Show-ActionResult "Create System Restore Point" $true
                        }
                        else {
                            Show-ActionResult "Create System Restore Point ($($result.Error))" $false
                        }
                        $CurrentPage = "Main"
                        $Breadcrumb = @("Main Menu")
                    }
                    '0' {
                        $LastError = $null
                        $CurrentPage = "Main"
                        $Breadcrumb = @("Main Menu")
                    }
                    default { $LastError = "Invalid selection." }
                }
            }

        }

    }
}

catch {
    Clear-Host
    Write-Host "A fatal error occurred:" -ForegroundColor Red
    Write-Host $_ -ForegroundColor DarkRed
    Wait-AnyKey
}

Clear-Host
Write-Host "Exiting..." -ForegroundColor DarkGray