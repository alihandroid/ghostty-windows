param(
    [string]$InstallerPath = (Join-Path $PSScriptRoot '..\..\dist\windows\install-dev.ps1')
)

# Run with -NoProfile under Windows PowerShell 5.1 or PowerShell 7. All
# fixtures are local Windows files; no executable is launched or input sent.
$ErrorActionPreference = 'Stop'

function Assert-True($condition, [string]$description) {
    if (-not $condition) { throw $description }
    Write-Output "PASS=$description"
}

function Write-Fixture([string]$path, [string]$content) {
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
    [System.IO.File]::WriteAllText($path, $content)
}

function Invoke-Install {
    & $InstallerPath -BuildDir $buildDir -InstallRoot $installRoot -DesktopDir $desktopDir | Out-Host
}

function Get-ShortcutTarget {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    try { return $shortcut.TargetPath }
    finally { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null }
}

function Assert-RejectedPayload([string]$description) {
    $previousShortcutHash = (Get-FileHash -LiteralPath $shortcutPath -Algorithm SHA256).Hash
    $previousBuildCount = @(Get-ChildItem -LiteralPath (Join-Path $installRoot 'builds') -Directory).Count
    $rejected = $false
    try { Invoke-Install }
    catch { $rejected = $true }
    Assert-True $rejected "$description is rejected"
    Assert-True ((Get-FileHash -LiteralPath $shortcutPath -Algorithm SHA256).Hash -eq $previousShortcutHash) "$description preserves the desktop shortcut"
    Assert-True ((Get-ShortcutTarget) -eq $newTarget) "$description preserves the installed target"
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $installRoot 'builds') -Directory).Count -eq $previousBuildCount) "$description does not create a deployment"
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ghostty-dev-install-' + [guid]::NewGuid().ToString('N'))
$buildDir = Join-Path $testRoot 'build payload'
$installRoot = Join-Path $testRoot 'installed builds'
$desktopDir = Join-Path $testRoot 'Desktop'
$shortcutPath = Join-Path $desktopDir 'Ghostty Dev.lnk'
$exePath = Join-Path $buildDir 'bin\ghostty.exe'
$dllPath = Join-Path $buildDir 'bin\conpty.dll'
$hostPath = Join-Path $buildDir 'bin\OpenConsole.exe'
$licensePath = Join-Path $buildDir 'share\licenses\conpty\LICENSE.txt'
$sentinelPath = Join-Path $buildDir 'share\terminfo\ghostty.terminfo'
$themesPath = Join-Path $buildDir 'share\ghostty\themes'
$integrationPath = Join-Path $buildDir 'share\ghostty\shell-integration'
$shell = $null
$heldExe = $null
try {
    Write-Fixture $exePath 'dummy development executable one'
    Write-Fixture $dllPath 'dummy console library one'
    Write-Fixture $hostPath 'dummy matching console host'
    Write-Fixture $licensePath 'dummy console license'
    Write-Fixture $sentinelPath 'dummy terminfo sentinel'
    Write-Fixture (Join-Path $themesPath 'Example Theme') 'palette = 0=#123456'
    Write-Fixture (Join-Path $themesPath 'nested\Another Theme') 'palette = 0=#abcdef'
    Write-Fixture (Join-Path $integrationPath 'powershell\ghostty-shell-integration.ps1') '# fixture integration'
    Write-Fixture (Join-Path $integrationPath 'bash\ghostty.bash') '# another integration fixture'
    $hiddenResourcePath = Join-Path $integrationPath 'zsh\.zshenv'
    Write-Fixture $hiddenResourcePath '# hidden integration fixture'
    [System.IO.File]::SetAttributes($hiddenResourcePath, [System.IO.FileAttributes]::Hidden)

    $shell = New-Object -ComObject WScript.Shell
    Invoke-Install
    Assert-True (Test-Path -LiteralPath $shortcutPath -PathType Leaf) 'first install creates the desktop shortcut'
    $firstTarget = Get-ShortcutTarget
    $firstBuild = Split-Path -Parent $firstTarget
    Assert-True ((Split-Path -Leaf $firstTarget) -eq 'ghostty.exe') 'shortcut targets the deployed executable'
    Assert-True ((Split-Path -Parent $firstBuild) -eq (Join-Path $installRoot 'builds')) 'deployment uses a local versioned build directory'
    Assert-True (-not $firstTarget.StartsWith('\\')) 'shortcut target is a local Windows path'
    $shortcut = $shell.CreateShortcut($shortcutPath)
    try {
        Assert-True ($shortcut.WorkingDirectory -eq [Environment]::GetFolderPath('UserProfile')) 'shortcut starts shells in the user home directory'
    } finally {
        [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null
    }
    foreach ($relativePath in @(
        'ghostty.exe',
        'conpty.dll',
        'OpenConsole.exe',
        'share\licenses\conpty\LICENSE.txt',
        'share\terminfo\ghostty.terminfo',
        'share\ghostty\themes\Example Theme',
        'share\ghostty\themes\nested\Another Theme',
        'share\ghostty\shell-integration\powershell\ghostty-shell-integration.ps1',
        'share\ghostty\shell-integration\bash\ghostty.bash',
        'share\ghostty\shell-integration\zsh\.zshenv'
    )) {
        $sourcePath = if ($relativePath -in @('ghostty.exe', 'conpty.dll', 'OpenConsole.exe')) {
            Join-Path $buildDir ('bin\' + $relativePath)
        } else { Join-Path $buildDir $relativePath }
        $deployedPath = Join-Path $firstBuild $relativePath
        Assert-True ((Test-Path -LiteralPath $deployedPath -PathType Leaf) -and
            (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $deployedPath -Algorithm SHA256).Hash) "complete portable layout includes $relativePath"
    }

    Invoke-Install
    Assert-True ((Get-ShortcutTarget) -eq $firstTarget) 'unchanged payload reuses its deployment'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $installRoot 'builds') -Directory).Count -eq 1) 'unchanged payload does not create another build'

    Write-Fixture (Join-Path $themesPath 'Example Theme') 'palette = 0=#654321'
    Invoke-Install
    $resourceTarget = Get-ShortcutTarget
    Assert-True ($resourceTarget -ne $firstTarget) 'a resource-only change creates a new deployment'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $resourceTarget) 'share\ghostty\themes\Example Theme')) -eq 'palette = 0=#654321') 'resource-only deployment contains the updated resource'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $firstBuild 'share\ghostty\themes\Example Theme')) -eq 'palette = 0=#123456') 'resource-only update leaves previous resources intact'

    $heldExe = [System.IO.File]::Open($resourceTarget, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    Write-Fixture $exePath 'dummy development executable two'
    Invoke-Install
    $newTarget = Get-ShortcutTarget
    Assert-True ($newTarget -ne $resourceTarget) 'a new executable deploys while the previous executable is held open'
    Assert-True ([System.IO.File]::ReadAllText($newTarget) -eq 'dummy development executable two') 'shortcut selects the newly built executable'
    Assert-True ([System.IO.File]::ReadAllText($resourceTarget) -eq 'dummy development executable one') 'updating never overwrites the previous executable'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $installRoot 'builds') -Directory).Count -eq 3) 'all previous builds remain available'
    $heldExe.Dispose()
    $heldExe = $null

    Write-Fixture $dllPath 'dummy console library two'
    Invoke-Install
    $backendTarget = Get-ShortcutTarget
    Assert-True ($backendTarget -ne $newTarget) 'a console backend update creates a new deployment'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $backendTarget) 'conpty.dll')) -eq 'dummy console library two') 'console backend update is deployed beside the executable'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $newTarget) 'conpty.dll')) -eq 'dummy console library one') 'console backend update preserves the previous build'
    $newTarget = $backendTarget

    foreach ($requiredFile in @($dllPath, $hostPath, $licensePath)) {
        $contents = [System.IO.File]::ReadAllText($requiredFile)
        Remove-Item -LiteralPath $requiredFile
        Assert-RejectedPayload ('missing ' + (Split-Path -Leaf $requiredFile))
        Write-Fixture $requiredFile $contents
    }

    Remove-Item -LiteralPath $exePath
    Assert-RejectedPayload 'missing executable'
    Write-Fixture $exePath 'dummy development executable two'

    Remove-Item -LiteralPath $sentinelPath
    Assert-RejectedPayload 'missing resource sentinel'
    Write-Fixture $sentinelPath 'dummy terminfo sentinel'

    foreach ($resourceDirectory in @($themesPath, $integrationPath)) {
        $savedDirectory = Join-Path $testRoot 'saved resource directory'
        Move-Item -LiteralPath $resourceDirectory -Destination $savedDirectory
        try { Assert-RejectedPayload ('missing ' + (Split-Path -Leaf $resourceDirectory) + ' directory') }
        finally { Move-Item -LiteralPath $savedDirectory -Destination $resourceDirectory }
    }
    Write-Output "PowerShell $($PSVersionTable.PSVersion) development install checks passed"
} finally {
    if ($null -ne $heldExe) { $heldExe.Dispose() }
    if ($null -ne $shell) { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
