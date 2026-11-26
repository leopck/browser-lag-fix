# BrowserLagFix.Volume: Windows volume isolation

Moves each Chromium profile's site file storage (`<User Data>\<Profile>\File System`) onto a small,
dynamically expanding virtual disk, and leaves a junction in its place. A page can then reserve at
most the size of that disk, and the expensive NTFS free-space scan happens on the small volume
instead of the system drive.

## Requirements

- Windows 10 or 11, Windows PowerShell 5.1 or PowerShell 7+
- An elevated session for install, uninstall and mount
- The affected browsers closed during install and uninstall

## Install

```powershell
Import-Module .\windows\BrowserLagFix.Volume
Install-BrowserLagFixVolume                                   # all detected Chromium browsers, 20 GB
Install-BrowserLagFixVolume -Browser Edge -SizeGB 10          # just Edge, 10 GB
Install-BrowserLagFixVolume -WhatIf                           # show what would happen
```

What it does:

1. Creates `C:\BrowserLagFix\browserlagfix.vhdx` (NTFS, expandable; it only uses disk space as sites store data)
   and mounts it at `C:\BrowserLagFix\mnt`.
2. For each profile: moves `File System` to `C:\BrowserLagFix\mnt\<Browser>-<id>\<Profile>\File System`,
   verifies file count and bytes, then creates the junction. If anything fails, the data is moved back.
3. Registers two scheduled tasks under `\BrowserLagFix\`:
   - `BrowserLagFix-Attach` (SYSTEM, at startup) re-attaches the disk on every boot.
   - `BrowserLagFix-Reconcile` (you, at logon) redirects profiles created after install.
4. Restricts `C:\BrowserLagFix` to SYSTEM, Administrators and the installing user.

Re-running is safe: already-redirected profiles and the existing disk are reused.

## Check

```powershell
Get-BrowserLagFixStatus
Get-BrowserLagFixProfile | Format-Table Browser, Profile, State
```

`State` is one of `Redirected` (protected), `Local` (not yet moved), `Missing` (the profile has never
used site files; it will be redirected by reconcile), or `RedirectedElsewhere` (already a link to
somewhere else; left alone).

## Uninstall

```powershell
Uninstall-BrowserLagFixVolume                 # move data back, remove tasks, delete the disk
Uninstall-BrowserLagFixVolume -KeepVirtualDisk
```

## Supported browsers

Edge (stable, Beta, Dev, Canary), Chrome (stable, Beta, Dev), Brave and Vivaldi are detected
automatically. For anything else, including WebView2 apps, pass `-UserDataRoot`.

## Troubleshooting

| Problem | Fix |
|---|---|
| Sites say storage is unavailable after a reboot | The disk didn't attach. Run `Mount-BrowserLagFixVolume` (elevated) and check the `BrowserLagFix-Attach` task and `C:\BrowserLagFix\browserlagfix.log`. |
| "Close these browsers first" | Quit the browser fully, including background apps (system tray), or end its processes. |
| A profile shows `Local` after creating it | It will be moved at next logon, or run `Invoke-BrowserLagFixReconcile` with the browser closed. |

## Testing

```powershell
Invoke-Pester tests/windows -Output Detailed                         # unit
Invoke-Pester tests/windows -Output Detailed -TagFilter Integration  # elevated: real 100 MB VHDX lifecycle
```
