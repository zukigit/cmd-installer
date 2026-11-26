# cmd-installer

Save long commands under short names.

```sh
./cmd-installer.sh gidcraft_mcp_up "gridcraft --control 6969"
gidcraft_mcp_up            # runs: gridcraft --control 6969
gidcraft_mcp_up --verbose  # runs: gridcraft --control 6969 --verbose
```

- One POSIX `sh` script that works on Debian/Ubuntu (`dash`) and RHEL/Fedora (`bash`).
- No sudo. Everything lives in `~/.local/cmd-installer/`, kept apart from system folders.
- The first run creates the bin folder and adds it to your `PATH`.

## Usage

```
cmd-installer.sh <name> "<command>"              install (short form)
cmd-installer.sh install <name> "<command>" [--force]
cmd-installer.sh uninstall <name>
cmd-installer.sh uninstall --all [--purge]
cmd-installer.sh list
cmd-installer.sh self-install
cmd-installer.sh help
```

| Command | What it does |
|---|---|
| `install` | Creates a command. Refuses to replace an existing one unless you pass `--force`. |
| `uninstall <name>` | Removes one command. |
| `uninstall --all` | Removes every command you installed (keeps `cmd-installer` itself). |
| `uninstall --all --purge` | Also removes `cmd-installer`, the PATH setup and the folder. A full reset. |
| `list` | Shows each command and what it runs. |
| `self-install` | Copies the script into its own bin folder, so you can run `cmd-installer` from anywhere. |

Names may use letters, digits, `.`, `_` and `-`, and must start with a letter or digit.

## How it works

```
~/.local/cmd-installer/
├── env.sh                  # adds bin/ to PATH (only once)
└── bin/
    ├── cmd-installer       # after self-install
    └── gidcraft_mcp_up     # one small wrapper script per command
```

Each wrapper looks like this:

```sh
#!/bin/sh
# managed-by: cmd-installer
# installed: 2026-11-26
gridcraft --control 6969 "$@"
```

The `managed-by` line marks files that cmd-installer created. Uninstall, `--all` and `--purge` only ever delete files with that mark.

The first install adds this block to `~/.bashrc` and `~/.profile`, and to `~/.bash_profile` and `~/.zshrc` if you have them:

```sh
# >>> cmd-installer >>>
[ -f "$HOME/.local/cmd-installer/env.sh" ] && . "$HOME/.local/cmd-installer/env.sh"
# <<< cmd-installer <<<
```

Open a new terminal afterwards, or run `. ~/.local/cmd-installer/env.sh` to use your commands right away.

## Things to know

- **Quotes and `$`**: the command is stored exactly as you type it, so wrap it in single quotes to keep variables for run time: `cmd-installer.sh home 'echo "$HOME"'`.
- **Extra arguments** are added at the end of the command. With pipes or `&&`, they go to the last command in the chain (`a | b` + args runs `a | b args`). Don't end a command with `;`, `&` or a `# comment`, because then the arguments would run as a separate command or be ignored.
- **sudo**: `sudo mycmd` won't find your commands, because sudo uses its own PATH. Run `sudo ~/.local/cmd-installer/bin/mycmd` instead.
- **Root**: the script refuses to run as root, because it would install into root's home.
- **fish**: not set up automatically. Add `fish_add_path ~/.local/cmd-installer/bin` to `~/.config/fish/config.fish`.

## Tests

```sh
tests/run.sh
```

Runs `tests/cases.sh` on the host and in these local podman images (it never pulls; missing images are skipped):

| Target | Distro | `/bin/sh` |
|---|---|---|
| host | Fedora 44 | bash |
| `docker.io/redhat/ubi10:latest` | RHEL 10.3 | bash |
| `ghcr.io/zeroclaw-labs/zeroclaw:debian` | Debian 12 | dash |

Each run uses a fresh temporary `HOME`, so your real startup files are never touched. `shellcheck` runs too if it's installed.
