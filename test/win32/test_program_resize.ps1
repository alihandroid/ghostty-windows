param([Parameter(Mandatory=$true)][string]$ExePath, [switch]$DiagnosticLog)

# This test never focuses a window or injects keyboard/mouse input. A controlled
# child emits VT requests after a file-based handshake with this test process.
$ErrorActionPreference = "Stop"
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ResizeTest {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
}
"@

function Wait-For($condition, $description) {
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (& $condition)) {
        if ((Get-Date) -gt $deadline) { throw "Timed out: $description" }
        Start-Sleep -Milliseconds 100
    }
}

function Assert-True($condition, $description) {
    if (-not $condition) { throw $description }
    Write-Output "PASS=$description"
}

foreach ($allowed in @("false", "true")) {
    $taskDir = Join-Path $env:TEMP ("ghostty-program-resize-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory $taskDir | Out-Null
    $escapedDir = $taskDir.Replace("'", "''")
    $childScript = @"
`$taskDir = '$escapedDir'
`$request = Join-Path `$taskDir 'request'
`$ack = Join-Path `$taskDir 'ack'
[IO.File]::WriteAllText((Join-Path `$taskDir 'ready'), 'ready')
`$last = ''
`$deadline = (Get-Date).AddMinutes(3)
while ((Get-Date) -lt `$deadline) {
    if (Test-Path `$request) {
        `$next = [IO.File]::ReadAllText(`$request)
        if (`$next -and `$next -ne `$last) {
            if (`$next -eq 'exit') { break }
            [Console]::Write([char]27 + '[' + `$next)
            [IO.File]::WriteAllText(`$ack, `$next)
            `$last = `$next
        }
    }
    Start-Sleep -Milliseconds 50
}
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
    $arguments = '--config-default-files=false --auto-update=off --shell-integration=none --vt-window-resize-allowed=' + $allowed +
        ' --command="powershell.exe -NoLogo -NoProfile -EncodedCommand ' + $encoded + '"'
    $startOptions = @{ FilePath = $ExePath; ArgumentList = $arguments; PassThru = $true }
    if ($DiagnosticLog) {
        $startOptions.RedirectStandardError = Join-Path $taskDir 'stderr.log'
        Write-Host "LOG=$taskDir"
    }
    $proc = Start-Process @startOptions
    try {
        Wait-For { Test-Path (Join-Path $taskDir 'ready') } "controlled child startup"
        Wait-For { $proc.Refresh(); $proc.MainWindowHandle -ne [IntPtr]::Zero } "test window"
        $window = $proc.MainWindowHandle
        [uint32]$ownerPid = 0
        [ResizeTest]::GetWindowThreadProcessId($window, [ref]$ownerPid) | Out-Null
        Assert-True ($ownerPid -eq $proc.Id) "window belongs to this test process"

        function Read-Size {
            $rect = New-Object ResizeTest+RECT
            if (-not [ResizeTest]::GetClientRect($window, [ref]$rect)) { throw "test window disappeared" }
            return @(($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
        }
        function Request-Size($sequence) {
            [IO.File]::WriteAllText((Join-Path $taskDir 'request'), $sequence)
            Wait-For {
                $ack = Join-Path $taskDir 'ack'
                (Test-Path $ack) -and ([IO.File]::ReadAllText($ack) -eq $sequence)
            } "resize $sequence emitted"
            Start-Sleep -Milliseconds 2000
            $probe = [IntPtr]::Zero
            Assert-True ([ResizeTest]::SendMessageTimeout($window, 0, [IntPtr]::Zero, [IntPtr]::Zero,
                0x0003, 2000, [ref]$probe) -ne [IntPtr]::Zero) "responsive after resize $sequence" | Out-Host
            return Read-Size
        }

        $before = Read-Size
        $after = Request-Size '8;12;50t'
        Write-Host "SIZE=opt-in:$allowed $($before -join 'x') -> $($after -join 'x')"
        $changed = $before[0] -ne $after[0] -or $before[1] -ne $after[1]
        Assert-True ($changed -eq ($allowed -eq "true")) "CSI 8 t obeys opt-in ($allowed)"
        if ($allowed -eq "true") {
            $before = $after
            # ConPTY may consume zero-valued window-manipulation requests
            # before forwarding them. Native zero-dimension behavior and
            # split/fullscreen/tab guards are covered by Window.zig tests.
            $after = Request-Size '8;14;60t'
            Write-Host "SIZE=second-resize $($before -join 'x') -> $($after -join 'x')"
            Assert-True ($before[1] -ne $after[1] -and $before[0] -ne $after[0]) "second resize changes both dimensions"
            $before = $after
            $after = Request-Size '8;16;70t'
            Write-Host "SIZE=third-resize $($before -join 'x') -> $($after -join 'x')"
            Assert-True ($before[0] -ne $after[0] -and $before[1] -ne $after[1]) "third resize changes both dimensions"
        }
        $result = [IntPtr]::Zero
        Assert-True ([ResizeTest]::SendMessageTimeout($window, 0, [IntPtr]::Zero, [IntPtr]::Zero,
            0x0003, 2000, [ref]$result) -ne [IntPtr]::Zero) "test window remains responsive"
    } finally {
        $proc.Refresh()
        if (-not $proc.HasExited) {
            # Only terminate the process tree created above, never other Ghostty instances.
            & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null
        }
    }
}
