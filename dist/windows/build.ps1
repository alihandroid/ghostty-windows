# Run cache maintenance and a build while holding the project's cache guard.
# Usage: .\dist\windows\build.ps1 [zig build arguments...]
# Set $env:ZIG to select a compiler. Compatible with Windows PowerShell 5.1.
# No param block: Zig options must be passed through rather than bound as
# PowerShell named parameters.
$BuildArgs = @($args)
$ErrorActionPreference = 'Stop'
$RepoDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

# Legacy PowerShell native argument passing can drop empty arguments and quotes.
# Encode argv explicitly using the Windows command-line escaping rules.
function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

Push-Location -LiteralPath $RepoDir
try {
    $CacheDir = [Environment]::GetEnvironmentVariable('ZIG_LOCAL_CACHE_DIR', 'Process')
    $CacheExplicit = $null -ne $CacheDir
    $BuildFile = $null
    if ($null -eq $CacheDir) { $CacheDir = Join-Path $RepoDir '.zig-cache' }
    for ($i = 0; $i -lt $BuildArgs.Count; $i++) {
        $arg = [string]$BuildArgs[$i]
        if ($arg -eq '--') { break }
        if ($arg -eq '--cache-dir') {
            $i++
            if ($i -eq $BuildArgs.Count) { throw 'Expected a path after --cache-dir.' }
            $CacheDir = [string]$BuildArgs[$i]
            $CacheExplicit = $true
        } elseif ($arg.StartsWith('--cache-dir=')) {
            $CacheDir = $arg.Substring('--cache-dir='.Length)
            $CacheExplicit = $true
        } elseif ($arg -eq '--build-file') {
            $i++
            if ($i -eq $BuildArgs.Count) { throw 'Expected a path after --build-file.' }
            $BuildFile = [string]$BuildArgs[$i]
        } elseif ($arg.StartsWith('--build-file=')) {
            $BuildFile = $arg.Substring('--build-file='.Length)
        }
    }
    if (-not $CacheExplicit -and $null -ne $BuildFile) {
        $BuildDir = [System.IO.Path]::GetDirectoryName($BuildFile)
        if ([string]::IsNullOrEmpty($BuildDir)) { $BuildDir = '.' }
        $CacheDir = Join-Path $BuildDir '.zig-cache'
    }
    if ($CacheDir.Length -eq 0) { $CacheDir = '.' }
    $CacheDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CacheDir)

    $ZigSelector = $env:ZIG
    if ([string]::IsNullOrEmpty($ZigSelector)) {
        $ZigSelector = 'zig'
        $zon = [System.IO.File]::ReadAllText((Join-Path $RepoDir 'build.zig.zon'))
        $RequiredZig = [regex]::Match($zon, 'minimum_zig_version\s*=\s*"([^"]+)"').Groups[1].Value
        $ProcessorArchitecture = $env:PROCESSOR_ARCHITEW6432
        if ([string]::IsNullOrEmpty($ProcessorArchitecture)) {
            $ProcessorArchitecture = $env:PROCESSOR_ARCHITECTURE
        }
        $ZigArchitecture = switch ($ProcessorArchitecture) {
            'AMD64' { 'x86_64' }
            'ARM64' { 'aarch64' }
            default { 'x86' }
        }
        $UserHomeDir = [Environment]::GetFolderPath('UserProfile')
        $LocalZig = Join-Path $UserHomeDir ".local\zig-versions\zig-$ZigArchitecture-windows-$RequiredZig\zig.exe"
        if (Test-Path -LiteralPath $LocalZig -PathType Leaf) { $ZigSelector = $LocalZig }
    }
    $ZigExe = (Get-Command -Name $ZigSelector -CommandType Application -ErrorAction Stop | Select-Object -First 1).Path

    $LauncherArgs = New-Object 'System.Collections.Generic.List[string]'
    foreach ($arg in @(
        'run', (Join-Path $RepoDir 'src\build\cache_prune.zig'), '-O', 'safe',
        '--cache-dir', (Join-Path $RepoDir '.zig-cache-maintenance'), '--',
        $CacheDir, $ZigExe, 'build'
    )) { $LauncherArgs.Add($arg) }
    foreach ($arg in $BuildArgs) { $LauncherArgs.Add([string]$arg) }

    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $ZigExe
    $start.WorkingDirectory = $RepoDir
    $start.UseShellExecute = $false
    $start.Arguments = (@($LauncherArgs | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $child = New-Object System.Diagnostics.Process
    $child.StartInfo = $start
    try {
        if (-not $child.Start()) { throw 'Failed to start Zig.' }
        $child.WaitForExit()
        $ExitCode = $child.ExitCode
    } finally {
        $child.Dispose()
    }
} finally {
    Pop-Location
}
exit $ExitCode
