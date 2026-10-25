param([Parameter(Mandatory=$true)][string]$ExePath)

# Requires WSL with Python 3 and zsh. All mouse messages target a validated
# child HWND belonging to this test; no global input or focus APIs are used.
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class MouseReportingTest {
    public static int ProcessId;
    public delegate bool EnumProc(IntPtr h, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder text, int count);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT rect);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr SendMessageTimeout(IntPtr h, uint message, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    public static IntPtr Check(IntPtr h) {
        uint pid;
        if (h == IntPtr.Zero || GetWindowThreadProcessId(h, out pid) == 0 || pid != ProcessId)
            throw new Exception("Refusing a window not owned by this test process");
        return h;
    }
    public static IntPtr Terminal(IntPtr parent) {
        IntPtr terminal = IntPtr.Zero;
        EnumProc callback = delegate(IntPtr h, IntPtr data) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            var name = new StringBuilder(128); GetClassName(h, name, name.Capacity);
            if (pid == ProcessId && name.ToString() == "GhosttyTerminal") terminal = h;
            return true;
        };
        EnumChildWindows(Check(parent), callback, IntPtr.Zero);
        return terminal;
    }
    public static string Title(IntPtr h) {
        var text = new StringBuilder(256); GetWindowText(Check(h), text, text.Capacity);
        return text.ToString();
    }
    public static void MoveMouse(IntPtr terminal) {
        var name = new StringBuilder(128); GetClassName(Check(terminal), name, name.Capacity);
        if (name.ToString() != "GhosttyTerminal") throw new Exception("Expected the test terminal HWND");
        RECT rect;
        if (!GetClientRect(terminal, out rect)) throw new Exception("Test terminal disappeared");
        int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
        if (width < 80 || height < 80) throw new Exception("Test terminal is too small");
        for (int i = 2; i <= 6; i += 2) {
            int x = width * i / 10, y = height / 2;
            IntPtr result;
            long position = (y << 16) | x;
            if (SendMessageTimeout(Check(terminal), 0x0200, IntPtr.Zero, new IntPtr(position), 3, 2000, out result) == IntPtr.Zero)
                throw new TimeoutException("Test-owned terminal did not process WM_MOUSEMOVE");
        }
    }
}
'@

$taskDir = Join-Path $env:TEMP ('ghostty-mouse-reporting-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskDir | Out-Null
$linuxTaskDir = & wsl.exe --exec wslpath -u $taskDir
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve the test directory in WSL.' }
$resultPath = Join-Path $taskDir 'result.json'
$titlePrefix = 'mouse-reporting-' + [guid]::NewGuid().ToString('N')
$childScript = @'
import json
import os
import re
import select
import subprocess
import termios
import time
import tty

task_dir = __TASK_DIR__
title_prefix = __TITLE_PREFIX__
checks = []
fd = 0
original = termios.tcgetattr(fd)
enable_mouse = b'\x1b[?1003h\x1b[?1006h'
reset_mouse = b'\x1b[?9;1000;1002;1003;1005;1006;1015;1016l'

def read_for(seconds):
    deadline = time.monotonic() + seconds
    data = bytearray()
    while len(data) < 4096:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            break
        chunk = os.read(fd, 4096 - len(data))
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)

def phase(name, reporting):
    read_for(0.2)
    # The parent waits for this title, proving that preceding mode changes
    # have reached Ghostty before it sends the targeted motion messages.
    os.write(1, b'\x1b]2;' + (title_prefix + '-' + name).encode() + b'\x07')
    ready = os.path.join(task_dir, 'go-' + name)
    deadline = time.monotonic() + 20
    while not os.path.exists(ready):
        if time.monotonic() >= deadline:
            raise TimeoutError('No targeted mouse messages for ' + name)
        time.sleep(0.05)
    data = read_for(0.7)
    reports = re.findall(rb'\x1b\[<\d+;\d+;\d+M', data)
    if reporting and not reports:
        raise AssertionError(f'{name}: expected SGR mouse reports, got {data!r}')
    if not reporting and data:
        raise AssertionError(f'{name}: mouse movement still entered terminal input: {data!r}')
    checks.append(name + (': mouse reports received' if reporting else ': mouse movement produces no input'))

try:
    tty.setraw(fd)
    read_for(0.5)
    os.write(1, enable_mouse)
    phase('application', True)

    integration = os.path.join(os.environ['GHOSTTY_RESOURCES_DIR'], 'shell-integration', 'zsh', 'ghostty-integration')
    if not os.path.isfile(integration):
        raise AssertionError('WSL resources path does not resolve to the installed zsh integration: ' + integration)
    # Capture the real integration hook, including the failed command status.
    # Override its tty fd after sourcing so a child shell need not acquire
    # this test's controlling terminal. Then send its output through ConPTY.
    script = 'source "$1"; _ghostty_fd=1; _ghostty_deferred_init >/dev/null; _ghostty_state=1; false; _ghostty_precmd'
    prompt = subprocess.run(['zsh', '-dfi', '-c', script, 'zsh', integration],
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=10)
    if prompt.returncode != 0 or reset_mouse not in prompt.stdout or b'\x1b]133;D;1\x07' not in prompt.stdout:
        raise AssertionError(f'zsh cleanup hook failed: exit={prompt.returncode}, stdout={prompt.stdout!r}, stderr={prompt.stderr!r}')
    checks.append('WSL path translation locates the real zsh cleanup hook')
    os.write(1, prompt.stdout)
    tty.setraw(fd)
    phase('local-prompt', False)

    os.write(1, enable_mouse)
    phase('next-application', True)
    result = {'status': 'pass', 'checks': checks}
except Exception as error:
    result = {'status': 'fail', 'checks': checks, 'error': str(error)}
finally:
    os.write(1, reset_mouse)
    termios.tcsetattr(fd, termios.TCSANOW, original)
    result_path = os.path.join(task_dir, 'result.json')
    with open(result_path + '.tmp', 'w', encoding='utf-8') as report:
        json.dump(result, report)
    os.replace(result_path + '.tmp', result_path)
'@
$childScript = $childScript.Replace('__TASK_DIR__', ($linuxTaskDir.Trim() | ConvertTo-Json -Compress))
$childScript = $childScript.Replace('__TITLE_PREFIX__', ($titlePrefix | ConvertTo-Json -Compress))
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($childScript))
$bootstrap = "exec(__import__('base64').b64decode('$encoded'))"
$arguments = '--config-default-files=false --auto-update=off --shell-integration=none --mouse-shift-capture=always' +
    ' --command="wsl.exe --exec python3 -c ' + $bootstrap + '"'
# Select the staged bundle instead of an older parent terminal's resources.
$inheritedResources = $env:GHOSTTY_RESOURCES_DIR
try {
    Remove-Item Env:GHOSTTY_RESOURCES_DIR -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $ExePath -ArgumentList $arguments -PassThru
} finally {
    $env:GHOSTTY_RESOURCES_DIR = $inheritedResources
}
function Wait-For($condition, $description) {
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (& $condition)) {
        if (Test-Path -LiteralPath $resultPath) {
            $report = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            if ($report.status -ne 'pass') { throw $report.error }
        }
        $proc.Refresh()
        if ($proc.HasExited -and -not (Test-Path -LiteralPath $resultPath)) {
            throw "Ghostty exited while waiting for $description"
        }
        if ((Get-Date) -gt $deadline) { throw "Timed out: $description. Diagnostics: $taskDir" }
        Start-Sleep -Milliseconds 100
    }
}
try {
    [MouseReportingTest]::ProcessId = $proc.Id
    Wait-For { $proc.Refresh(); $proc.MainWindowHandle -ne [IntPtr]::Zero } 'test window'
    $window = [MouseReportingTest]::Check($proc.MainWindowHandle)
    $terminal = [IntPtr]::Zero
    Wait-For { $script:terminal = [MouseReportingTest]::Terminal($window); $script:terminal -ne [IntPtr]::Zero } 'owned terminal child'
    foreach ($phase in @('application', 'local-prompt', 'next-application')) {
        Wait-For { [MouseReportingTest]::Title($window) -eq ($titlePrefix + '-' + $phase) } "$phase output marker"
        [MouseReportingTest]::MoveMouse($terminal)
        [IO.File]::WriteAllText((Join-Path $taskDir ('go-' + $phase)), 'sent')
    }
    Wait-For { Test-Path -LiteralPath $resultPath } 'mouse reporting results'
    $report = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    foreach ($check in $report.checks) { Write-Output "PASS=$check" }
    if ($report.status -ne 'pass') { throw $report.error }
} finally {
    $proc.Refresh()
    if (-not $proc.HasExited) {
        # The test child can exit between Refresh and taskkill.
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
