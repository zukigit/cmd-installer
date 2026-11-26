# Plan: `cmd-installer.sh`

## 1. Design decisions

| Topic | Decision | Why |
|---|---|---|
| Shell | POSIX `#!/bin/sh`, no bash-only syntax | Debian's `/bin/sh` is `dash` and RHEL/Fedora's is `bash`. Writing to POSIX means one script runs on both with no checks for which distro it's on. |
| Home folder | `~/.local/cmd-installer/` (bin in `~/.local/cmd-installer/bin`) | Kept apart from system folders and from `~/.local/bin`, the way Homebrew keeps its own prefix. Everything is in the user's home. |
| Privileges | **No sudo, ever.** Refuse to run as root. | Everything lives under `$HOME`. Running as root would install into root's home by mistake. |
| PATH | One env file `~/.local/cmd-installer/env.sh`, sourced from the user's shell startup files | No root access is needed. The env file adds the bin folder only if it's not already on PATH, so sourcing it twice is harmless. |
| Command format | One small wrapper script per command | It's easy to inspect and remove, needs no database, and survives reboots. |
| Ownership marker | Each wrapper has a `# managed-by: cmd-installer` line | Uninstall (single or all) only deletes files carrying the marker, so it can never remove a file it didn't create. |

### Folder layout

```
~/.local/cmd-installer/
├── env.sh                  # PATH snippet
└── bin/
    ├── cmd-installer       # the script itself (after self-install)
    └── gidcraft_mcp_up     # user commands
```

### Example wrapper

`~/.local/cmd-installer/bin/gidcraft_mcp_up`:

```sh
#!/bin/sh
# managed-by: cmd-installer
# installed: 2026-11-26
gridcraft --control 6969 "$@"
```

`"$@"` passes any extra arguments through, so `gidcraft_mcp_up --verbose` works.

### PATH setup

`~/.local/cmd-installer/env.sh`:

```sh
case ":$PATH:" in
  *":$HOME/.local/cmd-installer/bin:"*) ;;
  *) PATH="$HOME/.local/cmd-installer/bin:$PATH"; export PATH ;;
esac
```

This block is added to the startup files:

```sh
# >>> cmd-installer >>>
[ -f "$HOME/.local/cmd-installer/env.sh" ] && . "$HOME/.local/cmd-installer/env.sh"
# <<< cmd-installer <<<
```

Which files get the block:

| File | When | Covers |
|---|---|---|
| `~/.bashrc` | always (created if missing) | interactive bash terminals on both families |
| `~/.profile` | always (created if missing) | Debian login shells, dash, and desktop sessions |
| `~/.bash_profile` | only if it exists | RHEL/Fedora login shells (bash ignores `~/.profile` when this file exists) |
| `~/.zshrc` | only if it exists | zsh users |

Before adding the block, the script greps for the `>>> cmd-installer >>>` marker, so it's never added twice. `--purge` removes exactly the lines between the markers.

## 2. Usage

```
cmd-installer.sh <name> "<command>"            # short form, e.g. cmd-installer.sh gidcraft_mcp_up "gridcraft --control 6969"
cmd-installer.sh install <name> "<command>" [--force]
cmd-installer.sh uninstall <name>
cmd-installer.sh uninstall --all [--purge]
cmd-installer.sh list
cmd-installer.sh self-install
cmd-installer.sh help
```

## 3. Logic

1. **Bootstrap** (runs before `install` and `self-install`):
   - Exit with an error if run as root (`id -u` is 0).
   - Create `~/.local/cmd-installer/bin` if it's missing.
   - Write `env.sh` if it's missing.
   - Add the marker block to the startup files listed above, if it isn't there yet.
   - The first time, print: *"PATH updated. Open a new terminal, or run: `. ~/.local/cmd-installer/env.sh`"*.
2. **install**:
   - Check the name against `^[A-Za-z0-9][A-Za-z0-9._-]*$`. This rules out slashes, spaces and a leading `-`.
   - Reject an empty command, and reject the reserved name `cmd-installer`.
   - If the wrapper already exists, stop unless `--force` is given.
   - If `command -v <name>` finds the name elsewhere on PATH, warn that it shadows or is shadowed by an existing command.
   - Write the wrapper with `printf '%s\n'` to a temp file in the bin folder, `chmod 755`, then `mv` it into place. The command text is never expanded, and a half-written wrapper never exists.
3. **uninstall `<name>`**: check that the file exists and has the marker, then `rm` it. Otherwise print an error and exit with code 1.
4. **uninstall `--all`**: remove every file in the bin folder that has the marker, except `cmd-installer` itself. Print how many were removed.
   - `--purge` also removes the self-installed copy, `env.sh` and the marker blocks in the startup files, then deletes the `~/.local/cmd-installer` folder. If unmarked files are still in the folder, it keeps them (and the folder) and prints a warning, so purge never deletes a file it didn't create.
5. **list**: print each marked wrapper as `name → command`.
6. **self-install**: copy the running script to `~/.local/cmd-installer/bin/cmd-installer` with `chmod 755`, so `cmd-installer ...` works from anywhere. Running it again updates the copy.
7. **Exit codes**: 0 for success, 1 for user error, 2 for a missing prerequisite or running as root.

## 4. Edge cases

- **Commands with quotes or `$`**: the command string is written exactly as given, so `cmd-installer.sh x 'echo "$HOME"'` expands `$HOME` when `x` runs, not when it's installed.
- **Pipes or `&&` in the command**: this works, but `"$@"` gets attached to the last command in the chain. The README should say so.
- **sudo**: `sudo mycmd` won't find the command, because sudo uses its own PATH and root's home. This is expected and goes in the README.
- **fish**: not supported automatically. The README shows the one line to add by hand.
- **`set -eu`**: enable it and quote every variable.

## 5. Files in the repo

```
cmd-installer.sh      # the script
README.md             # usage, the PATH note, caveats
tests/run.sh          # test runner
tests/cases.sh        # the test cases, run inside each environment
```

## 6. Testing

Use **podman** with images that are already downloaded (no pulls), plus the current host:

| Target | Distro | `/bin/sh` |
|---|---|---|
| `docker.io/redhat/ubi10:latest` | RHEL 10.3 | bash |
| `ghcr.io/zeroclaw-labs/zeroclaw:debian` | Debian 12 (bookworm) | dash |
| current host | Fedora 44 | bash |

`zeroclaw:debian` is an app image, so the test runner overrides its entrypoint with `--entrypoint /bin/sh`.

How `tests/run.sh` works:

- **Containers**: `podman run --rm --pull=never --entrypoint /bin/sh -v "$PWD":/src:ro,Z <image> /src/tests/cases.sh`. The tests run as a non-root user created inside the container, because the script refuses to run as root.
- **Host**: run `tests/cases.sh` with `HOME` set to a fresh temp folder, so your real `~/.bashrc` and `~/.profile` are never touched.
- Print a pass/fail summary for each target, and exit non-zero if any target fails.

What `tests/cases.sh` checks:

- the first install creates the bin folder, `env.sh`, and the startup-file blocks
- a second install doesn't add the block twice
- `bash -lc <name>` and `bash -ic <name>` both find and run the command
- extra arguments pass through
- a command containing quotes and `$` is stored exactly as given
- invalid names and an empty command are rejected
- a duplicate install fails unless `--force` is given
- running as root is refused
- `list` shows the installed commands
- `self-install` works, and `cmd-installer list` runs from PATH
- uninstall of one name works
- `uninstall --all` leaves a non-marked file and the self-installed copy alone
- `--purge` removes the folder and the startup-file blocks

Also run `shellcheck -s sh` on both scripts if it's installed; skip that step with a note if it isn't.
