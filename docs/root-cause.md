# Root cause: websites can make Chromium reserve ~60% of a Windows drive

This document records how the problem was found and proven. All numbers are from one machine:
Windows 11 (build 26200), Microsoft Edge 158 (Chromium 158), 2 TB NVMe SSD (1.85 TB NTFS system
volume, ~1.09 TB free).

## Symptom

Random multi-second freezes, most noticeable in the browser, with CPU, RAM and GPU idle. Task
Manager showed nothing busy.

## Evidence chain

### 1. The OS: writes stalled at the file-system level

`Microsoft-Windows-Ntfs/Operational` logged bursts of **Event 147 — "An IO took more than 30000 ms
to complete"**. In one day there were 44 such events with latencies of **37–175 s**, for the browser's
own files (`Local Storage\leveldb`, `Code Cache`, temp files) and for unrelated processes. Historically
this event appeared about once or twice a month.

The hourly NTFS **Event 142** ("Summary of disk space usage") showed:

```
Available space was between 5.52 GB and 1.08 TB
Cached runs miss counts: Everything else: 3202
```

So within that hour the 1.85 TB volume had been briefly almost full. **Event 9** ("NTFS scanned
entire volume bitmap") accompanied it. `chkdsk /scan` found no corruption.

### 2. A flight-recorder trace: who allocated the space

A Windows Performance Recorder trace in memory mode ([profile](../diagnostics/opfs-guard.wprp)) was
saved automatically when free space dipped. CPU sampling with stacks showed the **browser process**
(not a renderer) doing:

```
msedge.dll → KernelBase!SetEndOfFile → Ntfs!NtfsSetEndOfFileInfo → NtfsAddAllocation
           → NtfsAllocateClusters → NtfsFindFreeBitmapRun
```

A second capture with file-I/O events recorded the exact resizes (`ResizeFileActivity`):

| Time | Size | File |
|---|---|---|
| 00:58:49.276 | 2.1 GB | `…\Profile 1\File System\005\t\00\00000005` |
| 00:58:49.517 | 4.3 GB | `…\File System\005\t\00\00000069` |
| 00:58:49.637 | **1,098.4 GB** (47 ms) | `…\File System\005\t\00\00000075` |
| 00:58:49.788 | 68.7 GB | `…\File System\005\t\00\00000083` |
| 00:58:49.935 – 51.7 | 103–108 GB ×14 | `…\File System\005\t\01\…` |

A System worker thread then spent about 45 s in `Ntfs.sys` (with `volsnap.sys`, because the volume has
shadow copies) repopulating its free-space cache. That is the period when other writes stall.

### 3. The storage folder: which site

`File System\Origins` (a LevelDB) maps the numbered folders to origins. Combined with the browser
history, each dip lined up with a retail site being opened (or still open in a background tab).

### 4. The page: which call

A diagnostic extension wrapped the storage APIs in the page's own JavaScript world and logged every
call with its arguments and stack. On one retail site it captured:

```
09:06:43.090  FileSystemWritableFileStream.truncate(8796093022207)   // 8 TiB
09:06:45.284  truncate(4393749257561)   // 4092 GiB
09:06:45.564  truncate(2196874619435)   // 2046 GiB
09:06:45.950  truncate(1098437309717)   // 1023 GiB  ← accepted: this is the dip
09:06:46.374  truncate(511 GiB) → 255.75 → 127.87 → 63.94 → 95.91 → 111.89 → … → 100.40 GiB
```

The stack showed obfuscated function names in code compiled from a string (`eval`) with source name
`(program)`, so it could not be tied to a script URL. This is typical of commercial bot-detection
and fingerprinting SDKs. Interleaved `navigator.storage.estimate()` calls show it also reads the
reported quota.

After the volume fix was installed, the same script was observed again: it continued its search
upward (1023 → 1534.5 → 1278.75 → … → 1124.9 GiB). It treats any error **other than**
`QuotaExceededError` (here, disk-full surfacing as `InvalidStateError`) as "below the quota". So the
probe measures the quota, which is 60% of the disk size, not free space.

## Controlled reproduction

[`repro/probe.html`](../repro/probe.html) performs the same binary search with nothing else on the page.

**Fresh profile on the 2 TB system drive:**

```
estimate(): quota = 10 GiB, usage = 0
truncate 8192 GiB → QuotaExceededError   (1 ms)
truncate 4096 GiB → QuotaExceededError   (1 ms)
truncate 2048 GiB → QuotaExceededError   (2 ms)
truncate 1024 GiB → OK                   (54 ms)
truncate 1088 GiB → OK                   (8,430 ms)
truncate 1090 GiB → OK                   (9,042 ms)
C: free: 1,092 GB → 2 GB → 1,090 GB
```

**Same browser, same page, profile's `File System` folder junctioned to a 20 GB VHDX:**

```
truncate 1024 GiB → InvalidStateError    (9 ms)   (volume full)
truncate   16 GiB → OK                   (4 ms)
truncate   18 GiB → OK                   (34 ms)
C: free: 1,090.9 → 1,090.8 GB, no dip, no NTFS stall events
```

The only change between the two runs is where the files physically live, and that change removed the
dip and the stall. That establishes the causal link.

## Why it happens

1. **Quota is derived from disk size.** Chromium lets an origin use up to ~60% of the total disk
   ([MDN](https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria)).
2. **Extending a file is a real allocation on NTFS.** Growing an OPFS file calls `SetEndOfFile` on an
   ordinary, non-sparse NTFS file, and NTFS allocates clusters immediately. The [File System spec](https://fs.spec.whatwg.org/)
   says the added zero bytes do not have to take up disk space. APFS and ext4 extend sparsely by default.
3. **Near-full allocation is pathological on NTFS.** NTFS keeps a cache of free runs. A giant allocation
   exhausts it and forces a full bitmap scan, which holds locks other writers need.
4. **The reported quota no longer reveals disk size, so scripts probe the enforced one.** In this build
   `estimate()` reports 10 GiB while `truncate()` accepts up to ~1.09 TB. A binary search on
   `QuotaExceededError` recovers the real value, which is roughly 60% of the disk size and a
   fingerprinting signal, and each "accepted" step is a real reservation.

## What the fixes change

- **Extension:** refuses above-cap growth in the page, before the browser is involved. The probe
  converges on the cap, so the reported and enforced quota agree and nothing leaks. It cannot see Web
  Workers or code that saves pristine API references from a fresh same-origin iframe; see the
  [threat model](threat-model.md).
- **Volume isolation:** whatever the source, the largest possible reservation is bounded by the virtual
  disk, and the full-bitmap scan happens on a 20 GB volume rather than the system drive. It does not
  hide the quota, because Chromium still computes it from the system drive.
- **Upstream:** sparse extension on Windows and/or bounding growth by free space would fix it for
  everyone ([report](chromium-bug-report.md)).
