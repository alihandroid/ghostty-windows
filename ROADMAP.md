# Windows Feature Roadmap

Close the Windows UI and distribution gaps while keeping the shared terminal
core aligned with upstream. Deliver tab overview, inspector, and installers
before the larger session-lifetime changes needed for undo and redo. Keep
security restrictions until a tested replacement is available.

## Phase 1 Tab overview

Status: title-list overview implemented and locally verified. Live thumbnails
remain planned.

- A native, searchable list shows the current window's tabs, including
  Unicode titles, keyboard navigation, switching, and whole-tab closing.
- `toggle_tab_overview` and the command palette open the overview.
- Close confirmation covers every split in a selected tab. Surface identities
  keep actions safe across tab reordering and child exits; background exits
  refresh the list without taking focus away from search.
- Native tests cover filtering, selection, lifecycle, and DPI behavior.
  End-to-end automation targets only test-owned window handles and checks
  session shutdown and final-window exit.
- Live thumbnails are a later increment, not part of the title-list overview.

## Phase 2 Inspector

Status: planned.

- Host the shared inspector in a Win32 window using Dear ImGui and OpenGL.
- Implement input, focus, DPI, redraw scheduling, and surface-close handling.
- Preserve render-thread ownership of WGL contexts and core lifetime guards.
- Verify terminal state inspection and event capture without leaking resources
  or exposing stale surface pointers.

## Phase 3 Installers

Status: planned.

- Add MSI and MSIX packaging alongside the portable ZIP.
- Keep the executable and resource tree together; verify configuration paths
  and launching PowerShell, cmd.exe, and WSL from an installed app.
- Test clean installation, upgrade, repair where supported, and uninstall
  without deleting user configuration.
- Establish publisher identity and signing for MSIX distribution. Release
  publishing and production signing remain maintainer operations.

## Phase 4 Undo and redo

Status: planned.

- Add a Windows undo stack for creating and closing windows, tabs, and splits.
- Retain closed sessions for the configured `undo-timeout`, with bounded
  resources and explicit expiry/shutdown cleanup.
- Preserve live processes and split layouts during that grace period.
  Recreating a dead process is not equivalent to restoring its session.
- Keep shell-command and terminal-application undo separate; this feature
  must not claim to undo commands already executed.

## Phase 5 Restricted file links

Status: security design required.

- Design confirmed local-document opening through an explicit viewer before
  considering broader path or `file:` URL support.
- Validate the final target, including shortcuts, reparse points, device and
  network paths, alternate data streams, and replacement races.
- Keep arbitrary shell dispatch blocked; extension checks alone are not a
  safe file classification policy.
- Add adversarial regression coverage before relaxing the current policy.

## Platform constraints

- `secure_input`: do not add a normal-window toggle that promises macOS-style
  keyboard protection. A separate protected input desktop would require its
  own threat model and user-experience design.
- CSI 8 t resizing is already opt-in. Test supported ConPTY versions and
  investigate upstream improvements, but do not promise delivery of requests
  ConPTY consumes before Ghostty receives them.

## Completion requirements

A phase is complete when its behavior is implemented, focused regression
tests pass, Windows debug and stripped release builds pass, and the README
and changelog describe its actual limits. Never run desktop-global input
tests on a shared working desktop. See [Testing](README.md#testing).
