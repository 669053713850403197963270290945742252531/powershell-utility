# =========================
# PARAMETERS
# =========================
param(
    [switch]$Relaunched
)

# =========================
# SELF-RELAUNCH FOR "RUN WITH POWERSHELL" / DOUBLE-CLICK
# =========================
if (-not $Relaunched -and $PSCommandPath) {
    $argList = @(
        '-NoLogo'
        '-NoExit'
        '-ExecutionPolicy', 'Bypass'
        '-File', "`"$PSCommandPath`""
        '-Relaunched'
    )
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList
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

$RegistryQOLNames = @{
    '1' = "Disable Windows Ads & Suggestions"
    '2' = "Disable Lock Screen Spotlight"
    '3' = "Enable Long File Paths"
    '4' = "Disable Game Bar"
    '5' = "Disable Startup Delay"
    '6' = "Enable Verbose Boot Messages"
    '7' = "Disable Telemetry"
}

$RegistryShortcutNames = @{
    '1' = "Add Take Ownership to Context Menu"
    '2' = "Add Open PowerShell Here"
    '3' = "Add Restart Explorer Shortcut"
    '4' = "Add Clear Clipboard Shortcut"
    '5' = "Add Safe Mode Boot Option"
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



function Pause-AnyKey {
    Write-Host ""
    Write-Host "Press any key to return..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Draw-Header {
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
    Pause-AnyKey
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
        $input = Read-Host

        if ([string]::IsNullOrWhiteSpace($input)) {
            Write-Host "Invalid input: empty or whitespace." -ForegroundColor Red
            continue
        }

        if ($input -notmatch '^\d+$') {
            Write-Host "Invalid input: numbers only." -ForegroundColor Red
            continue
        }

        $value = [int]$input
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


# =========================
# PAGE RENDERERS
# =========================
function Show-MainMenu {
    Draw-Header
    Write-Host "Select any of the below options to begin.`n"
    Write-Host "[1] Registry QOL Changes" -ForegroundColor Green
    Write-Host "[2] Registry Shortcuts" -ForegroundColor Green
    Write-Host "[3] Windows Password Configuration" -ForegroundColor Green
    Write-Host "[4] Uninstall Windows Program" -ForegroundColor Green
    Write-Host "[0] Exit" -ForegroundColor DarkRed
}

function Show-RegistryQOL {
    Draw-Header
    Write-Host "[1] Disable Windows Ads & Suggestions"
    Write-Host "[2] Disable Lock Screen Spotlight"
    Write-Host "[3] Enable Long File Paths"
    Write-Host "[4] Disable Game Bar"
    Write-Host "[5] Disable Startup Delay"
    Write-Host "[6] Enable Verbose Boot Messages"
    Write-Host "[7] Disable Telemetry"
    Write-Host "[0] Return"
}

function Show-RegistryShortcuts {
    Draw-Header
    Write-Host "[1] Add Take Ownership to Context Menu"
    Write-Host "[2] Add Open PowerShell Here"
    Write-Host "[3] Add Restart Explorer Shortcut"
    Write-Host "[4] Add Clear Clipboard Shortcut"
    Write-Host "[5] Add Safe Mode Boot Option"
    Write-Host "[0] Return"
}

function Show-PasswordMenu {
    Draw-Header
    Write-Host "Windows Password Configuration`n"
    Write-Host "[1] Change minimum password age (days)"
    Write-Host "[2] Change maximum password age (days)"
    Write-Host "[3] Change minimum password length"
    Write-Host "[4] Change lockout threshold"
    Write-Host "[5] Change lockout duration (minutes)"
    Write-Host "[0] Return"
}

function Show-UninstallProgramMenu {
    Draw-Header
    Write-Host "Uninstall Windows Program`n"
    Write-Host "Enter the name of a built-in Windows app to remove."
    Write-Host "Examples: Get Help, Get Started, Game Bar, Xbox, People, Windows Backup"
    Write-Host ""
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
                    '0' { exit }
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
                    $name = "[${choice}] $($RegistryQOLNames[$choice])"
                    Show-ActionResult $name $true
                }
                else {
                    $LastError = "Invalid selection."
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
                    $name = "[${choice}] $($RegistryShortcutNames[$choice])"
                    Show-ActionResult $name $true
                }
                else {
                    $LastError = "Invalid selection."
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
                $input = Read-Host "Program name (or 0 to return)"

                if ($input -eq "0") {
                    $CurrentPage = "Main"
                    $Breadcrumb = @("Main Menu")
                }
                elseif ([string]::IsNullOrWhiteSpace($input)) {
                    $LastError = "You must enter a program name."
                }
                else {
                    try {
                        $result = Uninstall-WindowsApp $input

                        if ($result.Success -and $result.Protected.Count -gt 0) {
                            Show-ActionResult "Could not uninstall '$input'. Protected system app(s): $($result.Protected -join ', ')" $false
                        }
                        elseif ($result.Success) {
                            Show-ActionResult "Uninstalled '$input'" $true
                        }
                        else {
                            Show-ActionResult "'$input' cannot be uninstalled (may be system-protected)" $false
                        }
                    }
                    catch {
                        Show-ActionResult "Failed to uninstall '$input': $_" $false
                    }
                }
            }

        }

    }
}

catch {
    Clear-Host
    Write-Host "A fatal error occurred:" -ForegroundColor Red
    Write-Host $_ -ForegroundColor DarkRed
    Pause-AnyKey
}

Clear-Host
Write-Host "Exiting..." -ForegroundColor DarkGray