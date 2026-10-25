param([Parameter(Mandatory=$true)][string]$ExePath)

# Exercise real terminal replies through ConPTY and WSL without sending any
# keyboard/mouse input. A bounded child echoes replies like a disconnected
# SSH session whose local tty has echo enabled. Requires WSL with Python 3.
$ErrorActionPreference = 'Stop'
$taskDir = Join-Path $env:TEMP ('ghostty-reply-feedback-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskDir | Out-Null
$resultPath = Join-Path $taskDir 'result.json'
$linuxResultPath = & wsl.exe --exec wslpath -u $resultPath
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the test result path in WSL.' }

$childScript = @'
import json
import os
import re
import select
import termios
import time
import tty

result_path = __RESULT_PATH__
checks = []
fd = 0
original = termios.tcgetattr(fd)

def read_for(seconds):
    deadline = time.monotonic() + seconds
    data = bytearray()
    while len(data) < 1024:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            break
        chunk = os.read(fd, 1024 - len(data))
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)

def check_reply(name, query, expected):
    os.write(1, query)
    response = read_for(1)
    if not (re.fullmatch(expected, response) if isinstance(expected, re.Pattern) else response == expected):
        raise AssertionError(f'{name}: expected {expected!r}, got {response!r}')
    checks.append(f'{name}: legitimate query still gets its reply')
    os.write(1, response)
    repeated = read_for(1)
    if repeated:
        raise AssertionError(f'{name}: echoed reply generated more input: {repeated!r}')
    checks.append(f'{name}: echoed reply generates no further input')

try:
    tty.setraw(fd)
    # Discard startup negotiation before testing application queries.
    read_for(0.5)
    # ConPTY can answer DA2 itself; its reported identity differs from Ghostty.
    check_reply('secondary device attributes', b'\x1b[>c', re.compile(rb'\x1b\[>\d+;\d+;\d+c'))
    check_reply('default keyboard flags', b'\x1b[?u', b'\x1b[?0u')
    os.write(1, b'\x1b[>1u')
    check_reply('enabled keyboard flags', b'\x1b[?u', b'\x1b[?1u')

    check_reply('glyph support', b'\x1b_25a1;s\x1b\\', b'\x1b_25a1;s;fmt=glyf\x1b\\')
    # Two empty simple glyphs let us prove that reflecting a clear reply
    # neither clears unrelated registrations nor generates another reply.
    for cp in (b'e0a0', b'e0a1'):
        os.write(1, b'\x1b_25a1;r;cp=' + cp + b';reply=0;AAAAAAAAAAAAAA==\x1b\\')
    check_reply('glyph coverage', b'\x1b_25a1;q;cp=e0a1\x1b\\',
                b'\x1b_25a1;q;cp=e0a1;status=glossary\x1b\\')
    check_reply('clear one glyph', b'\x1b_25a1;c;cp=e0a0\x1b\\', b'\x1b_25a1;c;status=0\x1b\\')
    check_reply('unrelated glyph survives echoed clear', b'\x1b_25a1;q;cp=e0a1\x1b\\',
                b'\x1b_25a1;q;cp=e0a1;status=glossary\x1b\\')
    check_reply('clear all glyphs', b'\x1b_25a1;c\x1b\\', b'\x1b_25a1;c;status=0\x1b\\')
    check_reply('cleared glyph coverage', b'\x1b_25a1;q;cp=e0a1\x1b\\',
                b'\x1b_25a1;q;cp=e0a1;status=\x1b\\')

    # Deny policies exercise real application replies without clipboard
    # access or permission dialogs on the shared desktop.
    check_reply('clipboard write denial', b'\x1b]5522;type=write:id=feedback\x1b\\',
                b'\x1b]5522;type=write:status=EPERM:id=feedback\x1b\\')
    check_reply('clipboard read denial', b'\x1b]5522;type=read:id=feedback;dGV4dC9wbGFpbg==\x1b\\',
                b'\x1b]5522;type=read:status=EPERM:id=feedback\x1b\\')
    result = {'status': 'pass', 'checks': checks}
except Exception as error:
    result = {'status': 'fail', 'checks': checks, 'error': str(error)}
finally:
    os.write(1, b'\x1b[<u')
    termios.tcsetattr(fd, termios.TCSANOW, original)
    with open(result_path + '.tmp', 'w', encoding='utf-8') as report:
        json.dump(result, report)
    os.replace(result_path + '.tmp', result_path)
'@
$childScript = $childScript.Replace('__RESULT_PATH__', ($linuxResultPath.Trim() | ConvertTo-Json -Compress))
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($childScript))
# This bootstrap has no spaces or double quotes, avoiding a second layer of
# Windows command-line quoting inside Ghostty's --command argument.
$bootstrap = "exec(__import__('base64').b64decode('$encoded'))"
$arguments = '--config-default-files=false --auto-update=off --shell-integration=none' +
    ' --clipboard-read=deny --clipboard-write=deny' +
    ' --command="wsl.exe --exec python3 -c ' + $bootstrap + '"'
$proc = Start-Process -FilePath $ExePath -ArgumentList $arguments -PassThru
try {
    $deadline = (Get-Date).AddSeconds(60)
    while (-not (Test-Path -LiteralPath $resultPath)) {
        $proc.Refresh()
        if ($proc.HasExited -and -not (Test-Path -LiteralPath $resultPath)) {
            throw 'Ghostty exited before the reply test completed.'
        }
        if ((Get-Date) -gt $deadline) { throw "Timed out waiting for the reply test. Diagnostics: $taskDir" }
        Start-Sleep -Milliseconds 100
    }
    $report = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    foreach ($check in $report.checks) { Write-Output "PASS=$check" }
    if ($report.status -ne 'pass') { throw $report.error }
} finally {
    $proc.Refresh()
    if (-not $proc.HasExited) {
        # The child can exit between Refresh and taskkill. Capture native
        # stderr without turning that normal race into a PowerShell error;
        # a failed cleanup is still an error if our process remains alive.
        $cleanup = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\taskkill.exe') `
            -ArgumentList @('/PID', $proc.Id, '/T', '/F') -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput (Join-Path $taskDir 'cleanup.stdout.log') `
            -RedirectStandardError (Join-Path $taskDir 'cleanup.stderr.log')
        if ($cleanup.ExitCode -ne 0) {
            $proc.Refresh()
            if (-not $proc.HasExited) { throw "Could not stop test process $($proc.Id). Diagnostics: $taskDir" }
        }
    }
}
