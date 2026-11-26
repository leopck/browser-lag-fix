# OPFS `truncate()` allocates real disk space on Windows up to ~60% of the volume, so any web page can briefly fill the system drive and stall all disk writes for minutes

**Component:** Blink>Storage>FileSystem (OPFS) / Storage>Quota
**Platform:** Windows 11 (10.0.26200), NTFS system drive, 2 TB NVMe SSD
**Reproduction & tooling:** https://github.com/leopck/browser-lag-fix (`repro/probe.html`, `diagnostics/`)
**Version:** Microsoft Edge 158.0.4370.33 (Chromium 158). Chrome on Windows should use the same code path but has not been tested.

## Summary

A page can call `FileSystemWritableFileStream.truncate(n)` with `n` up to about 60% of the total disk size (1.09 TB here). On Windows this becomes `SetEndOfFile` on a normal (non-sparse) NTFS file, so NTFS **really allocates** the clusters.

- The system drive's free space drops from about 1.09 TB to about 2 GB for a few seconds.
- NTFS has to scan the whole volume bitmap to satisfy the allocation.
- Writes from **every process on the machine** stall. Windows logged `Microsoft-Windows-Ntfs/Operational` Event 147 ("An IO took more than 30000 ms to complete") with latencies of 37–175 s, for the browser itself and for unrelated processes.

This is being exploited in the wild, apparently for fingerprinting:
- An obfuscated third-party script, loaded via eval with sourceURL `(program)`, binary-searches the largest size `truncate()` accepts on several retail sites.
- The sequence: 8192 GiB → 4092 → 2046 → 1023 (accepted) → 511 → … → 100.4 GiB, in about 7 s.
- This looks like a way to recover the disk size or quota now that `navigator.storage.estimate()` no longer reveals it. In this build, `estimate()` reports a 10 GiB quota.

## Minimal reproduction

The attached `probe.html` must be served from a secure context, for example `http://127.0.0.1`. It:
1. calls `navigator.storage.estimate()`;
2. creates OPFS files and calls `createWritable()` then `truncate(size)`, binary-searching from 8 TiB down;
3. aborts and removes each file afterwards.

**Observed, with a fresh profile on the 2 TB system drive:**

```
estimate: quota = 10 GiB, usage = 0
truncate 8192 GiB  -> QuotaExceededError   (1 ms)
truncate 4096 GiB  -> QuotaExceededError   (1 ms)
truncate 2048 GiB  -> QuotaExceededError   (2 ms)
truncate 1024 GiB  -> OK                   (54 ms)
truncate 1088 GiB  -> OK                   (8430 ms)
truncate 1090 GiB  -> OK                   (9042 ms)
C: free space during run: 1092 GB -> 2 GB -> 1090 GB
```

**Control:** the same page and the same browser build, with the profile's `File System` directory placed on a separate 20 GB NTFS volume (a junction to a VHDX).

```
truncate 1024 GiB -> InvalidStateError (9 ms)   [volume full]
truncate   16 GiB -> OK (4 ms)
truncate   18 GiB -> OK (34 ms)
C: free space: unchanged (1090.9 -> 1090.8 GB), no stall
```

## Evidence from the in-the-wild occurrences (ETW, WPR)

- The browser process (not the renderer) calls `KernelBase!SetEndOfFile`, which reaches `Ntfs!NtfsSetEndOfFileInfo`, then `NtfsAddAllocation`, `NtfsAllocateClusters` and `NtfsFindFreeBitmapRun`.
- The file is `...\User Data\<profile>\File System\<NNN>\t\00\000000xx`.
- `ResizeFileActivity` NewSize values of 2.1, 4.3, **1098.4**, 68.7, 103, 107 GB, … recorded within 2 s.
- A System worker thread spins in `Ntfs.sys` for about 45 s afterwards, with `volsnap.sys` on the stack because the volume has shadow copies.
- NTFS Event 142 ("Summary of disk space usage") recorded available space between 5.52 GB and 1.08 TB within one hour, with 3202 cached-run misses. NTFS Event 9 ("scanned entire volume bitmap") was also logged.

## Expected

- The spec says bytes added by extending a file *"[don't] have to actually be written to disk and take up disk space"* (fs.spec.whatwg.org, `truncate`). Extending an OPFS file should not reserve physical clusters up front on Windows. For example, mark OPFS files sparse (`FSCTL_SET_SPARSE`), which matches the behaviour on APFS and ext4.
- Alternatively, `truncate()` growth should be limited by available free space, not only by the quota (~60% of total capacity), and preferably capped well below what the quota allows.
- The quota `estimate()` reports (10 GiB) and the size `truncate()` will accept (~1.09 TB) are wildly inconsistent. That gap is exactly what the probing scripts exploit.
- Minor: running out of disk is reported to the page as `InvalidStateError` rather than `QuotaExceededError`.

## Additional observation: the probe measures the quota, not free space

With the profile's `File System` directory on a 20 GB volume, the in-the-wild script kept searching
*upward* (1023 → 1534.5 → 1278.75 → … → 1124.9 GiB). It treats any error other than
`QuotaExceededError` as "below the limit", so it recovers the enforced quota (about 60% of the
system disk) even when nothing can be allocated. The gap between `estimate()` (10 GiB) and the
enforced quota is therefore still a disk-size fingerprinting vector, independent of the allocation
problem.

## Impact

- Any website can freeze disk I/O for the whole machine for tens of seconds to minutes.
- It repeats every time such a page loads, including from background tabs.
- The bigger the disk, the worse it gets.
- It is not visible to the user as anything other than "the PC randomly lags".
