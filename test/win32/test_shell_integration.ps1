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
Write-Output "PowerShell $($PSVersionTable.PSVersion) shell integration checks passed"
