# Diagnostics

These tools prove whether OPFS probes are what is stalling *your* machine. They need an elevated
PowerShell.

## 1. Check the event log (no setup)

```powershell
Get-WinEvent -LogName Microsoft-Windows-Ntfs/Operational |
  Where-Object Id -in 147, 142, 9 | Select-Object -First 30 TimeCreated, Id, Message
```

- **147** "An IO took more than 30000 ms to complete": the stall. Look at the process name and file.
- **142** "Summary of disk space usage": a line like *"Available space was between 5 GB and 1 TB"* is the dip.
- **9** "NTFS scanned entire volume bitmap": the expensive recovery.

## 2. Catch it as it happens

```powershell
wpr -start .\diagnostics\opfs-guard.wprp           # flight recorder: keeps the last ~minute in memory
.\diagnostics\Watch-FreeSpace.ps1 -SaveTrace       # logs dips and saves the trace automatically
```

On a dip, `%USERPROFILE%\OpfsGuardDiagnostics\free-space.log` gets:

```
DIP START free=62.2 GB (baseline 1093.3 GB)
  site storage Profile 1\File System\005 = https_www.example-shop.com_0 (written 00:58:50)
  trace: ...\dip-20261126-005850.etl
DIP END free=1092.6 GB (min 62.2 GB)
```

`opfs-guard.wprp` captures CPU sampling, context switches, ready-thread stacks, disk I/O, file I/O
(including resizes with stacks), DPC/ISR, and GPU/DWM activity. Its buffers are capped at about
640 MB of kernel memory. The stock `GeneralProfile` + `CPU` + `GPU` + `DiskIO` profiles reserved
about 6 GB on the test machine, enough to cause lag of their own.

## 3. Read the trace

Open the `.etl` in [Windows Performance Analyzer](https://learn.microsoft.com/windows-hardware/test/wpt/windows-performance-analyzer):

- **Storage → File I/O**: filter *Type* to `SetInfo`. Large *Size* values for `msedge.exe`/`chrome.exe` on
  `…\File System\NNN\t\…` are the probe.
- **Computation → CPU Usage (Sampled)**: stacks through `NtfsSetEndOfFileInfo` → `NtfsAllocateClusters`
  in the browser process, and a `System` thread busy in `Ntfs.sys` afterwards.

Stop the recorder with `wpr -cancel`.
