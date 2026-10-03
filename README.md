[English](README.md) | [Русский](README.ru.md)

# opencode-termux

Installer for [opencode](https://opencode.ai) in **Termux** on Android/arm64 — no Waydroid, no chroot, no `proot` in the default mode.

```bash
pkg install curl
curl -fsSL https://raw.githubusercontent.com/0xScodyx/opencode-termux/main/opencode-termux.sh -o opencode-termux.sh
bash opencode-termux.sh
```

Verified with opencode **v2.0.22** on Termux/aarch64.

> The script's own CLI messages are in Russian; this README is the English documentation.

---

## Why this exists

The official installer (`curl -fsSL https://opencode.ai/v2/install | bash`) does not work on Android, and this is not a broken environment:

| # | Problem | Consequence |
|---|---------|-------------|
| 1 | the opencode binary is `ET_EXEC` (non-PIE) | Android ≥ 5 requires PIE, so bionic's linker (`/system/bin/linker64`) rejects it |
| 2 | the binary hardcodes `/lib/ld-linux-aarch64.so.1` as its interpreter | that file does not exist on Android at all |
| 3 | opencode is built against glibc, Termux is bionic | incompatible libc |

A common claim on forums is that "the binary isn't PIE, so Android can never run it". That is not true. The Android **kernel** loads ELF binaries, not bionic, so all you need is a real glibc loader pointed at by `PT_INTERP`. opencode then runs directly, with no emulation layer. What still applies is Android's **seccomp policy**: it forbids some syscalls, and where that happens the process dies with `SIGSYS` — see [Troubleshooting](#troubleshooting).

## What the script does

1. Installs `glibc-repo` + `glibc-runner` — a glibc built for Termux (`$PREFIX/glibc`).
2. Resolves the latest version via `https://opencode.ai/update/api/latest/cli/npm`.
3. Downloads the `@opencode/cli-linux-arm64` tarball from npm and verifies its **sha512** against what the registry reports (falls back to sha1 from `dist.shasum`).
4. **Patches `PT_INTERP` in place at the byte level**: the interpreter string is written over `.interp` + `.note`, and the segment's `p_filesz` is extended. Segment count, `vaddr` values and every file offset stay untouched.
5. Creates a launcher in `$PREFIX/bin/opencode` that drops `LD_PRELOAD` (bionic libraries break glibc processes), sets `LD_LIBRARY_PATH` to glibc and `TMPDIR=$PREFIX/tmp` (Android has no `/tmp`, and Bun unpacks its native OpenTUI module there).
6. Intercepts `opencode upgrade`: the built-in upgrade would wipe the interpreter patch, so it re-runs this script instead.

### Why not `patchelf`

`patchelf` **must not** be used on this binary. This was the most interesting finding while building this.

`patchelf --set-interpreter` rebuilds the LOAD segments and shifts the image base:

```
before:  LOAD offset=0x000000  vaddr=0x200000
after:   LOAD offset=0x000000  vaddr=0x1e0000   ← image moved down by 128 KiB
```

opencode is a non-PIE `ET_EXEC` with absolute addresses baked into the code, so after that rewrite every reference to `.rodata`/`.got` is off by 0x20000 and the process dies with `SIGSEGV`.

Worse, the breakage is nearly invisible: `readelf -S` still shows the `.bun` section in place, the file size looks normal, and the `.bun` payload is byte-for-byte identical. The binary simply refuses to run.

Measured on aarch64 (qemu + arm64 Ubuntu):

| variant | result |
|---|---|
| pristine from npm | `opencode v2.0.22`, exit 0 |
| after `patchelf` 0.18.0 | `readelf: the PHDR segment is not covered by a LOAD segment` |
| after `patchelf` 0.19.2 | `Segmentation fault`, exit 139 |
| after byte-level patch | `opencode v2.0.22`, exit 0 |

After the patch, `readelf -lW` shows exactly one difference — `INTERP p_filesz 0x1b → 0x22` — plus zeroed `NOTE` segments (their contents are overwritten by the new string). Not a single byte of file size changes.

## Requirements

* Termux on **arm64/aarch64** (a regular phone)
* `curl`, `tar`, `coreutils` (`dd`, `od`, `wc`) — available from the Termux repos, the script verifies them itself
* ~300 MB of free space (see below)

## Options

The command above works on its own — no flags, nothing to choose. The script
installs glibc, downloads opencode, checks that it starts, and if this phone's
Android blocks the syscalls it needs, installs the seccomp shim by itself.

Flags exist as tools, not as decisions you have to make:

```
-f, --force           reinstall even if this version is already installed
    --diag            show the environment and why the launch failed (strace)
    --fix-seccomp     install the Android seccomp shim (usually automatic)
    --uninstall       remove opencode
-v, --version <ver>   specific version (e.g. 2.0.22)
    --method <m>      native | proot — only if you want to set it by hand
    --skip-checksum   skip tarball sha512 verification
    --keep-tmp        do not remove temporary files
-h, --help            show help
```

## Disk space

Peak usage is **261 MB** (measured, not guessed):

| mode | what happens | peak |
|---|---|---|
| normal | 86 MB tarball + 191 MB binary | ~280 MB |
| streaming | `curl \| tar` straight into the target, tarball never written | ~200 MB |

Below 300 MB of free space the script switches to streaming mode on its own (with a warning that checksum verification is skipped). Below 220 MB it refuses to run and tells you what to do. Leftovers from previous attempts in `$PREFIX/tmp/opencode-termux.*` are cleaned automatically.

Override the threshold with `OPENCODE_MIN_FREE_MB=500 bash opencode-termux.sh`.

## Troubleshooting

### `opencode killed by SIGSYS` / `invalid system call`

This is Android's seccomp policy: the system forbids some syscalls that opencode makes. The installation itself succeeded — a process dies.

It is device-specific: on many phones nothing is blocked and opencode runs fine, on some (more often vendor ROMs with a stricter policy, such as a TECNO Spark Go 1 on Android 14) even `opencode --version` is killed.

The installer recognises this and fixes it by itself: on exit code 159 it installs a **shim** and retries the launch. You don't have to do anything.

The shim is a tiny library that turns the seccomp trap into a plain `-ENOSYS`. It is built without libc and disables itself inside bionic processes (`git`, `sh`), so it cannot harm the child processes opencode spawns. To install or reinstall it by hand:

```bash
bash opencode-termux.sh --fix-seccomp
```

Why that works: Bun (opencode's engine) calls `close_range` at startup and later needs `statx`, `openat2`, `pidfd_open`, `clone3` and `epoll_pwait2`. Each one has a fallback path via `-ENOSYS`, but Android sends `SIGSYS` instead of an error, so the process dies before the fallback can run. The shim rewrites the return register in the `ucontext` to `-ENOSYS`, and Bun takes its own fallback.

If the shim doesn't help, the script can find the blocked syscall for you — it prints the environment, runs opencode under `strace` and names the call that was killed:

```bash
bash opencode-termux.sh --diag
```

Or do it by hand:

```bash
pkg install strace
strace -f -o $PREFIX/tmp/oc.strace opencode serve
tail -3 $PREFIX/tmp/oc.strace
```

Please [open an issue](https://github.com/0xScodyx/opencode-termux/issues) with the `--diag` output if opencode does not start — knowing the exact syscall is what makes such a device fixable.

### `CANNOT LINK EXECUTABLE "cat": ... has bad ELF magic`

You exported `LD_LIBRARY_PATH` to the glibc directory yourself, or sourced the launcher. Android's libc is named `libc.so`, so Termux utilities pick up glibc's `libc.so` (a text linker script) and fail. Unset it:

```bash
unset LD_LIBRARY_PATH
```

The launcher never sets it globally on purpose — it passes it to opencode alone, so your shell and Termux utilities stay clean.

### Black TUI screen

```bash
TMPDIR=$PREFIX/tmp opencode
```

The launcher sets `TMPDIR` itself, but you need it when running the binary directly.

### `No space left on device`

```bash
rm -rf $PREFIX/tmp/opencode-termux.*   # leftovers from earlier attempts
apt clean; apt autoremove -y
TMPDIR=/path/with/space bash opencode-termux.sh   # different partition
```

### proot — last resort, by hand

If neither the shim nor the diagnostics help (or you just want an environment that is guaranteed to work):

```bash
bash ~/.opencode/install-termux.sh --method proot
```

Installs proot-distro with Debian and runs opencode inside it. Slower and needs noticeably more disk space, but the TUI is guaranteed to work. The installer never goes there on its own: proot is a deliberate choice, not a silent fallback.

## Maintenance

```bash
opencode upgrade                    # intercepted, the interpreter patch survives
bash ~/.opencode/install-termux.sh --force
bash ~/.opencode/install-termux.sh --uninstall
```

Files after installation:

```
$PREFIX/bin/opencode                        launcher in $PATH
$HOME/.opencode/bin/opencode                second launcher, for when $PREFIX/bin is unavailable
$HOME/.opencode/libexec/opencode            the real binary
$HOME/.opencode/install-termux.sh           installer copy (needed by the upgrade hook)
```

## How this was tested

The full install path was exercised on real aarch64 via `qemu-aarch64` (Docker + `binfmt_misc`, arm64 Ubuntu image): download, unpack, `PT_INTERP` patch, launch, unpacking of the native OpenTUI module into `TMPDIR`, idempotency, `--force`, the upgrade hook, `--uninstall`, and the streaming mode.

The shim was verified in three honest parts, because it cannot be reproduced end to end on an x86-64 host:

1. **The trap mechanism** — against a real host seccomp (`SECCOMP_RET_TRAP` on `close_range`): without the shim the process gets exit 159 (128+SIGSYS), with the shim `close_range` returns `ENOSYS` and the process keeps running.
2. **Bun's behaviour on `ENOSYS`** — on the real aarch64 opencode binary with a seccomp filter forcing `close_range → ENOSYS`: it starts normally.
3. **Shim installation on device** — on the real aarch64 binary, the constructor runs, the handler is installed (`rt_sigaction` returns 0) and the launch is not disturbed.

Honest limitation: qemu-user cannot be the source of an aarch64 seccomp trap — the host kernel rejects a filter built for a foreign architecture — so the trap exactly as a phone produces it cannot be installed under qemu. Final verification needs real hardware.

## Security

* The tarball is verified against the sha512/sha1 reported by the npm registry itself, so a substituted package is detected
* HTTPS everywhere it matters
* The script never requires root and writes nothing outside `$HOME` and `$PREFIX`

## Links

* opencode: https://opencode.ai
* this repository: https://github.com/0xScodyx/opencode-termux

## License

[MIT](LICENSE)
