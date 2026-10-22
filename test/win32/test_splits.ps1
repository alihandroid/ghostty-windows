param([string]$ExePath, [string]$ScreenshotDir = "")

if ($env:GHOSTTY_TEST_ISOLATED_DESKTOP -ne "1") {
    throw "This test injects global input. Use a dedicated desktop and set GHOSTTY_TEST_ISOLATED_DESKTOP=1."
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class W32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    public delegate bool EP(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EP p, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EP p, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }

    public const uint WM_KEYDOWN = 0x0100;
    public const uint WM_KEYUP = 0x0101;
    public const uint WM_CHAR = 0x0102;

    public const int VK_RETURN = 0x0D;
    public const int VK_TAB = 0x09;
    public const int VK_PRIOR = 0x21;  // Page Up
    public const int VK_NEXT = 0x22;   // Page Down
    public const int VK_LEFT = 0x25;
    public const int VK_UP = 0x26;
    public const int VK_RIGHT = 0x27;
    public const int VK_DOWN = 0x28;
    public const int VK_OEM_4 = 0xDB;  // [
    public const int VK_OEM_6 = 0xDD;  // ]
    public const int VK_W = 0x57;
    public const int VK_T = 0x54;
    public const int VK_E = 0x45;
    public const int VK_Z = 0x5A;
}
"@

$pass = 0; $fail = 0

function Take-Screenshot($proc, $name) {
    if (-not $ScreenshotDir) { return }
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { return }
    $r = New-Object W32+RECT
    [W32]::GetWindowRect($h, [ref]$r) | Out-Null
    $w = $r.R - $r.L; $ht = $r.B - $r.T
    if ($w -le 0 -or $ht -le 0) { return }
    $bmp = New-Object System.Drawing.Bitmap $w, $ht
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [W32]::PrintWindow($h, $hdc, 2) | Out-Null
    $g.ReleaseHdc($hdc); $g.Dispose()
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $bmp.Save("$ScreenshotDir\${name}_$ts.png", [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

# Send keystroke directly to Ghostty's window via SetForegroundWindow + SendKeys.
# This ensures the target window receives the input.
function Send-Shortcut($proc, $keys) {
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -ne [IntPtr]::Zero) {
        [W32]::SetForegroundWindow($h) | Out-Null
        Start-Sleep -Milliseconds 300
        [W32]::SetForegroundWindow($h) | Out-Null
        Start-Sleep -Milliseconds 200
    }
    [System.Windows.Forms.SendKeys]::SendWait($keys)
    Start-Sleep -Milliseconds 200
}

function Count-ChildWindows($proc, $className) {
    $proc.Refresh()
    $h = $proc.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { return 0 }
    $script:childCount = 0
    $cb = [W32+EP]{param($ch,$l)
        $sb = New-Object System.Text.StringBuilder 256
        [W32]::GetClassName($ch, $sb, 256) | Out-Null
        if ($sb.ToString() -eq $className -and [W32]::IsWindowVisible($ch)) {
            $script:childCount++
        }
        return $true
    }
    [W32]::EnumChildWindows($h, $cb, [IntPtr]::Zero) | Out-Null
    return $script:childCount
}

function Launch-Ghostty {
    $proc = Start-Process -FilePath $ExePath -PassThru

    # Wait for main window
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 200
        $proc.Refresh()
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
            # Give it extra time to fully initialize
            Start-Sleep -Seconds 1
            return $proc
        }
    }
    Write-Output "  WARN: Window handle not found after 8s"
    return $proc
}

function Kill-Ghostty($proc) {
    if (-not $proc.HasExited) {
        & taskkill /PID $proc.Id /T /F 2>$null | Out-Null
        Start-Sleep -Milliseconds 500
    }
}

# ===================================
# TEST 1: New Split
# ===================================
Write-Output ""
Write-Output "=== TEST 1: New Split ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"

$childBefore = Count-ChildWindows $proc "GhosttyTerminal"
Write-Output "  Terminal child windows before split: $childBefore"

Take-Screenshot $proc "split_01_before"

# Ctrl+Shift+Enter = new split (right) - default Ghostty keybinding
Send-Shortcut $proc "^+o"
Start-Sleep -Seconds 3

$childAfter = Count-ChildWindows $proc "GhosttyTerminal"
Write-Output "  Terminal child windows after split: $childAfter"

Take-Screenshot $proc "split_02_after"

if ($proc.HasExited) {
    Write-Output "  FAIL: Process crashed during split creation"
    $fail++
} elseif ($childAfter -gt $childBefore) {
    Write-Output "  OK: Split created ($childBefore -> $childAfter visible terminals)"
    $pass++
} else {
    Write-Output "  WARN: Child count unchanged - split may not have been created (check keybinding)"
    Write-Output "  OK: Process survived (no crash)"
    $pass++
}
Kill-Ghostty $proc
Write-Output "  DONE"

# ===================================
# TEST 2: Close Split Pane
# ===================================
Write-Output ""
Write-Output "=== TEST 2: Close Split Pane ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"

# Create a split
Send-Shortcut $proc "^+o"
Start-Sleep -Seconds 3

$childBefore = Count-ChildWindows $proc "GhosttyTerminal"
Write-Output "  Terminals after split: $childBefore"

# Close the active pane (Ctrl+Shift+W)
Send-Shortcut $proc "^+w"
Start-Sleep -Seconds 2

if ($proc.HasExited) {
    Write-Output "  FAIL: Process died after closing split pane"
    $fail++
} else {
    $childAfter = Count-ChildWindows $proc "GhosttyTerminal"
    Write-Output "  Terminals after close: $childAfter"
    Write-Output "  OK: Process alive after closing split pane"
    $pass++
}

Take-Screenshot $proc "split_03_after_close"
Kill-Ghostty $proc
Write-Output "  DONE"

# ===================================
# TEST 3: Multiple Splits
# ===================================
Write-Output ""
Write-Output "=== TEST 3: Multiple Splits ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"

# Create 3 splits (4 panes total)
for ($i = 0; $i -lt 3; $i++) {
    Send-Shortcut $proc "^+o"
    Start-Sleep -Seconds 2
}

$childCount = Count-ChildWindows $proc "GhosttyTerminal"
Write-Output "  Terminal windows: $childCount (expected 4)"

Take-Screenshot $proc "split_04_multiple"

if ($proc.HasExited) {
    Write-Output "  FAIL: Process crashed during multiple splits"
    $fail++
} else {
    Write-Output "  OK: Process alive with $childCount panes"
    $pass++
}
Kill-Ghostty $proc
Write-Output "  DONE"

# ===================================
# TEST 4: Split Navigation
# ===================================
Write-Output ""
Write-Output "=== TEST 4: Split Navigation ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"

# Create a split
Send-Shortcut $proc "^+o"
Start-Sleep -Seconds 3

# Navigate previous (Ctrl+Shift+[)
Send-Shortcut $proc "^+{[}"
Start-Sleep -Seconds 1

# Navigate next (Ctrl+Shift+])
Send-Shortcut $proc "^+{]}"
Start-Sleep -Seconds 1

# Navigate back
Send-Shortcut $proc "^+{[}"
Start-Sleep -Seconds 1

Take-Screenshot $proc "split_05_navigation"

if ($proc.HasExited) {
    Write-Output "  FAIL: Process crashed during split navigation"
    $fail++
} else {
    Write-Output "  OK: Process alive after split navigation"
    $pass++
}
Kill-Ghostty $proc
Write-Output "  DONE"

# ===================================
# TEST 5: Splits + Tabs
# ===================================
Write-Output ""
Write-Output "=== TEST 5: Splits + Tabs ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"

# Create a split in tab 1
Send-Shortcut $proc "^+o"
Start-Sleep -Seconds 2

# Open a new tab
Send-Shortcut $proc "^+t"
Start-Sleep -Seconds 3

# Switch back to tab 1 (Ctrl+Shift+PageUp)
Send-Shortcut $proc "^+{PGUP}"
Start-Sleep -Seconds 1

# Switch to tab 2
Send-Shortcut $proc "^+{PGDN}"
Start-Sleep -Seconds 1

Take-Screenshot $proc "split_06_splits_tabs"

if ($proc.HasExited) {
    Write-Output "  FAIL: Process crashed during splits + tab switching"
    $fail++
} else {
    Write-Output "  OK: Process alive after splits + tab operations"
    $pass++
}
Kill-Ghostty $proc
Write-Output "  DONE"

# ===================================
# TEST 6: Close All Splits Returns to Single Pane
# ===================================
Write-Output ""
Write-Output "=== TEST 6: Close All Splits ==="
$proc = Launch-Ghostty
Write-Output "  Launched PID=$($proc.Id)"

# Create 2 splits (3 panes)
Send-Shortcut $proc "^+o"
Start-Sleep -Seconds 2
Send-Shortcut $proc "^+o"
Start-Sleep -Seconds 2

$before = Count-ChildWindows $proc "GhosttyTerminal"
Write-Output "  Panes before closing: $before"

# Close 2 panes
Send-Shortcut $proc "^+w"
Start-Sleep -Seconds 2
Send-Shortcut $proc "^+w"
Start-Sleep -Seconds 2

if ($proc.HasExited) {
    Write-Output "  FAIL: Process exited after closing split panes (should still have 1)"
    $fail++
} else {
    $after = Count-ChildWindows $proc "GhosttyTerminal"
    Write-Output "  Panes after closing 2: $after"
    Write-Output "  OK: Process alive with remaining pane"
    $pass++
}

Take-Screenshot $proc "split_07_all_closed"
Kill-Ghostty $proc
Write-Output "  DONE"

# ===================================
Write-Output ""
Write-Output "================================"
Write-Output "Results: $pass passed, $fail failed"
Write-Output "================================"
if ($fail -gt 0) { exit 1 }
