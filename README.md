# DiskMap

A native macOS app for finding what's filling your disk and clearing it out.

- **Sunburst and treemap** views of the same scan (toggle in the toolbar). Colors show the
  kind of space: LLM models, Xcode & simulators, code & worktrees, Docker, temp & Trash, ...
- **Fast:** scans on every core with `getattrlistbulk(2)`. About 1 minute for 11M files,
  about 2–2.5 minutes for a full 850 GB disk (a little over 3× faster than `du`).
- **Sizes you can trust:** allocated bytes on disk. Hard links and APFS clones (uv, bun,
  pnpm, Finder "Duplicate") are counted once, so totals line up with `df` instead of
  inflating by hundreds of GB.
- **Delete with confirmation:** select items (list, or click / ⌘-click in the chart), then
  **Move to Trash…** (⌘⌫). A sheet lists exactly what will go and the total; nothing
  moves until you confirm. Totals update immediately, with no rescan. Anything replaced
  or moved since the scan (or reached through a folder that became a link) is left alone.
- **Rescan This Folder** (right-click, or ⌘R for the folder you're in) refreshes one folder
  after it changes outside DiskMap, without rescanning the whole disk.

## Build and run

```bash
./scripts/bundle.sh
open DiskMap.app
```

Requires macOS 15+ and Xcode. `swift test` runs the core tests.

**Full Disk Access:** without it, folders macOS protects (Mail, Messages, parts of
`~/Library`) can't be read. The status bar lists them. To include them, add
`DiskMap.app` under System Settings › Privacy & Security › Full Disk Access, then rescan.
The app is ad-hoc signed, so a rebuild may need the grant again.

## Things worth knowing

- **Trash doesn't free space until you empty it.** Moving to Trash is recoverable, and the
  bytes stay on disk until the Trash is emptied.
- **Shared clone data shows under one copy.** When several files are clones of each other,
  the first one scanned carries the shared bytes and the others show only what deleting
  them alone would free. So a `.venv` cloned from `~/.cache/uv` can show near zero: deleting
  it alone really does free almost nothing.
- **"Macintosh HD" scans `/System/Volumes/Data`,** the volume holding everything you can
  delete. Other volumes are skipped.
- Files under 1 MB are grouped per folder as "N small files" to keep memory down
  (about 660 MB for a 20M-file disk).
