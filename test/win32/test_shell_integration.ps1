param(
    [string]$IntegrationPath = (Join-Path $PSScriptRoot '..\..\src\shell-integration\powershell\ghostty-shell-integration.ps1')
)

# Run in a fresh powershell.exe or pwsh.exe process with -NoProfile. This test
# captures VT output in memory and never launches a GUI or injects input.
$ErrorActionPreference = 'Stop'

function Assert-True($condition, $description) {
    if (-not $condition) { throw $description }
    Write-Output "PASS=$description"
}

# Capture registration without loading PSReadLine or accepting console input.
function Get-Module {
    param([string]$Name, [string]$ErrorAction)
    if ($Name -ne 'PSReadLine') { throw "Unexpected module lookup: $Name" }
    return [pscustomobject]@{ Name = 'PSReadLine' }
}
function Set-PSReadLineKeyHandler {
    param([string]$Key, [scriptblock]$ScriptBlock)
    if ($Key -ne 'Enter') { throw "Unexpected key handler: $Key" }
    $Script:enterHandler = $ScriptBlock
}
function prompt { 'ghostty-test> ' }

$originalOutput = [Console]::Out
$originalFeatures = $env:GHOSTTY_SHELL_FEATURES
$originalExitCode = $global:LASTEXITCODE
$capture = New-Object System.IO.StringWriter
$Script:enterHandler = $null
try {
    [Console]::SetOut($capture)
    $env:GHOSTTY_SHELL_FEATURES = 'cursor,title'
    . $IntegrationPath

    $firstPrompt = prompt
    $firstOutput = $capture.ToString()
    $capture.GetStringBuilder().Clear() | Out-Null

    $global:LASTEXITCODE = 37
    $secondPrompt = prompt
    $secondOutput = $capture.ToString()
    $preservedExitCode = $global:LASTEXITCODE
    $capture.GetStringBuilder().Clear() | Out-Null

    $GhosttyFeatures = @()
    $Script:__ghostty_prompt_state = 'initial'
    $null = prompt
    $minimalOutput = $capture.ToString()
    $capture.GetStringBuilder().Clear() | Out-Null

    # PSDrive names can contain terminal controls that Windows rejects in
    # ordinary filenames. Exercise a real provider location, keeping the VT
    # output captured so the test never touches the desktop clipboard.
    $unicodeName = [string][char]0x6d4b + [char]0x8bd5
    $driveName = 'ghostty-' + $unicodeName + '-' + [guid]::NewGuid().ToString('N') +
        [char]7 + [char]27 + ']52;c;SGVsbG8=' + [char]7 + [char]0x7f + [char]0x9b
    # DEL and C1 controls are valid Windows filename characters. Cover the
    # title's leaf as well as the drive-qualified working directory.
    $directoryName = 'ghostty-shell-' + [guid]::NewGuid().ToString('N') + '-' +
        $unicodeName + [char]0x7f + [char]0x9b
    $hostileRoot = Join-Path $env:TEMP $directoryName
    $originalLocation = Get-Location
    try {
        New-Item -ItemType Directory -Path $hostileRoot | Out-Null
        New-PSDrive -Name $driveName -PSProvider FileSystem -Root $hostileRoot | Out-Null
        Set-Location -LiteralPath ($driveName + ':\')
        $hostileCwd = (Get-Location).Path -replace '\\', '/' -replace '\p{Cc}', ''
        $hostileLeaf = $directoryName -replace '\p{Cc}', ''
        $GhosttyFeatures = @('title')
        $Script:__ghostty_prompt_state = 'initial'
        $null = prompt
        $hostileOutput = $capture.ToString()
    } finally {
        Set-Location -LiteralPath $originalLocation.Path
        Remove-PSDrive -Name $driveName -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $hostileRoot -ErrorAction SilentlyContinue
    }
} finally {
    [Console]::SetOut($originalOutput)
    $capture.Dispose()
    $env:GHOSTTY_SHELL_FEATURES = $originalFeatures
    $global:LASTEXITCODE = $originalExitCode
}

$esc = [string][char]27
$bel = [string][char]7
$cwd = (Get-Location).Path -replace '\\', '/'
$hostname = [System.Net.Dns]::GetHostName()
$leaf = Split-Path -Leaf (Get-Location)
Assert-True ($firstPrompt -eq 'ghostty-test> ' -and $secondPrompt -eq $firstPrompt) 'original prompt text is preserved'
Assert-True ($firstOutput.StartsWith($esc + ']133;A' + $bel)) 'first prompt starts with a real ESC semantic marker'
Assert-True ($firstOutput.Contains($esc + '[5 q')) 'cursor sequence uses a real ESC'
Assert-True ($firstOutput.Contains($esc + "]7;file://$hostname/$cwd" + $bel)) 'working directory sequence uses a real ESC'
Assert-True ($firstOutput.Contains($esc + "]2;$leaf" + $bel)) 'title sequence uses a real ESC'
Assert-True ($firstOutput.EndsWith($esc + ']133;B' + $bel)) 'prompt end uses a real ESC'
Assert-True ($secondOutput.StartsWith($esc + ']133;D;0' + $bel)) 'subsequent prompt reports command completion'
Assert-True ($preservedExitCode -eq 37) 'LASTEXITCODE is preserved'
Assert-True (-not $minimalOutput.Contains($esc + '[5 q') -and -not $minimalOutput.Contains($esc + ']2;')) 'optional cursor and title features can be disabled'
Assert-True ($null -ne $Script:enterHandler) 'Enter handler is registered without accepting input'
Assert-True (-not $hostileOutput.Contains($esc + ']52;')) 'provider location cannot inject OSC clipboard commands'
Assert-True ($hostileOutput.Contains($esc + "]7;file://$hostname/$hostileCwd" + $bel)) 'provider directory reports strip C0 and C1 controls'
Assert-True ($hostileOutput.Contains($esc + "]2;$hostileLeaf" + $bel)) 'directory titles strip DEL and C1 controls'
Assert-True ($hostileOutput.Contains($unicodeName)) 'directory reports preserve Unicode names'
Write-Output "PowerShell $($PSVersionTable.PSVersion) shell integration checks passed"
