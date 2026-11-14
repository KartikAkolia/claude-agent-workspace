# Copying ISO Files Between NVMe Drives with rsync

Written against rsync 3.5.2 (protocol 33) on the CachyOS laptop, with the flags checked against that version's `rsync --help`. The paths below are placeholders. Swap in the real mount points.

## Recommended command

```bash
rsync -ah --info=progress2 --preallocate /mnt/nvme1/isos/ /mnt/nvme2/isos/
```

`-a` is archive mode (`-rlptgoD`), which copies recursively and keeps permissions, timestamps, symlinks and ownership. `-h` prints sizes in a readable form such as `4.2G`. `--info=progress2` shows one progress line for the whole transfer instead of one per file, which reads better for a handful of large files. `--preallocate` reserves each file's full size before writing, which reduces fragmentation on ext4 and XFS for multi-GB files.

The trailing `/` on the source matters: it copies the *contents* of `isos/`. Without it, rsync creates `/mnt/nvme2/isos/isos/`.

## Flags to leave out

Skip `-z`. Compression only costs CPU on a local copy, and ISOs barely compress anyway. Skip `-W` too, because whole-file transfer (no delta algorithm) is already the default when both paths are local. Don't use `-c` on the first copy either: it reads every file on both sides before transferring.

## Copying only ISOs from a mixed folder

```bash
rsync -ahm --info=progress2 --preallocate \
  --include='*/' --include='*.iso' --exclude='*' \
  /mnt/nvme1/downloads/ /mnt/nvme2/isos/
```

`-m` (`--prune-empty-dirs`) drops directories that would end up empty after filtering.

## Useful extras

```bash
rsync -ahn ...                                       # dry run: show what would be copied
rsync -ah --partial ...                              # keep a half-copied file if interrupted
rsync -ahc --dry-run --itemize-changes SRC/ DST/     # verify afterwards: no output means identical
```

For a stronger check, compare `sha256sum` output against the distro's published checksums. That also confirms the original downloads weren't corrupted.

## When cp is enough

For a one-off copy into an empty directory, `cp -a --reflink=never SRC/. DST/` is about as fast. rsync is better for repeat runs, because it skips files that are already present and unchanged.
