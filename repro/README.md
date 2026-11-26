# Reproduction

`probe.html` does what the in-the-wild scripts do, and nothing else. It binary-searches the largest size
`FileSystemWritableFileStream.truncate()` will accept in the page's Origin Private File System, then
removes every file it created.

> **Warning:** on an unprotected Windows machine this briefly fills the system drive to within a few
> GB and can freeze disk I/O for seconds to minutes. Save your work first.

```bash
python repro/serve.py            # serves http://127.0.0.1:8765/probe.html
```

Open the URL in the browser under test. Watch the system drive's free space (Task Manager →
Performance → Disk, or `Get-PSDrive C` in a loop). Results are printed and appended to `results.jsonl`.

For an isolated run that leaves your profile alone, start a throwaway instance:

```powershell
& "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe" --user-data-dir="$env:TEMP\opfs-repro" --no-first-run http://127.0.0.1:8765/probe.html
```

## Expected results

| Setup | Largest accepted | Free space on C: | Per-call time |
|---|---|---|---|
| Unprotected (Windows, 2 TB drive) | ~1,090 GiB | drops to a few GB | 8–9 s |
| Volume isolation (20 GB) | ~18 GiB | unchanged | ms |
| Extension (cap 10 GiB) | 10 GiB | unchanged | < 1 ms |
