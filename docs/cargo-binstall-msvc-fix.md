# Fixing `cargo install cargo-binstall` on Windows: MSVC linker missing

## Symptom

Running `cargo install cargo-binstall` (or building any Rust crate) from Git Bash fails during linking with an error like:

```
error: linking with `link.exe` failed: exit code: 1
  ...
  = note: link: extra operand 'C:\...\build_script_build....rcgu.o'
          Try 'link --help' for more information.

note: you may need to install Visual Studio build tools with the "C++ build tools" workload
```

## Root cause

Two separate issues combine to produce this error:

1. **MSVC C++ Build Tools were not installed.** The active Rust toolchain (`rustup show`) was `x86_64-pc-windows-msvc`, which requires the real MSVC linker (`link.exe`) and Windows SDK from Visual Studio Build Tools. Neither was present (`cl.exe`, `link.exe` under a VS install path did not exist; no `vswhere.exe`).
2. **Git Bash's PATH shadows `link.exe`.** Git for Windows ships its own `link.exe` at `/usr/bin/link.exe`, a coreutils hardlink utility, unrelated to the MSVC linker. Because it's earlier on Git Bash's `PATH` (and no MSVC `link.exe` existed at all), cargo invoked the wrong binary. The error text `link: extra operand ... Try 'link --help'` is literally coreutils `link`'s usage message, not MSVC's — which is what makes this error so confusing.

## Fix

### 1. Install Visual Studio Build Tools with the C++ workload

```bash
winget install --id Microsoft.VisualStudio.2022.BuildTools --silent --override "--wait --quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

This installs MSVC (`cl.exe`, `link.exe`) and the Windows 10/11 SDK under:

```
C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\<version>\bin\Hostx64\x64\
```

### 2. Build/install from an MSVC-configured shell, not plain Git Bash

Git Bash's `PATH` ordering will still shadow the real `link.exe` even after installing Build Tools. Load the MSVC environment first via `vcvars64.bat`, then run cargo in the same shell:

```bat
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
cargo install cargo-binstall
```

Easiest ways to do this in practice:

- Use the **"x64 Native Tools Command Prompt for VS 2022"** Start Menu shortcut (installed automatically with Build Tools) — it runs `vcvars64.bat` for you.
- Or, from Git Bash, write the two lines above to a `.bat` file and run it with `cmd //c path/to/file.bat`.

### 3. Verify

```bash
cargo-binstall -V
```

Should print the installed version (e.g. `1.22.0`).

## Going forward

- Any `cargo install <crate>` that needs to **compile from source** on Windows needs the same MSVC-loaded shell — not plain Git Bash — until the Git Bash `PATH` shadowing is addressed separately (e.g. by reordering `PATH` or removing/renaming `/usr/bin/link.exe`).
- Once `cargo-binstall` itself is installed, most future crate installs can go through `cargo binstall <crate>` instead, which fetches prebuilt binaries and generally avoids invoking the linker at all — sidestepping this whole class of problem.
