#!/bin/sh
# cmd-installer: save long commands under short names.
# POSIX sh, works on Debian (dash) and RHEL/Fedora (bash). No sudo needed.

set -eu

PROG=cmd-installer
CI_HOME="$HOME/.local/cmd-installer"
BIN_DIR="$CI_HOME/bin"
ENV_FILE="$CI_HOME/env.sh"
SELF_PATH="$BIN_DIR/$PROG"

MARKER="# managed-by: cmd-installer"
BLOCK_BEGIN="# >>> cmd-installer >>>"
BLOCK_END="# <<< cmd-installer <<<"

# ---------------------------------------------------------------- helpers

info() { printf '%s\n' "$*"; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
die() {
	code=1
	case "$1" in [0-9]) code=$1; shift ;; esac
	printf '%s: error: %s\n' "$PROG" "$*" >&2
	exit "$code"
}

usage() {
	cat <<'EOF'
Usage:
  cmd-installer.sh <name> "<command>"              install (short form)
  cmd-installer.sh install <name> "<command>" [--force]
  cmd-installer.sh uninstall <name>
  cmd-installer.sh uninstall --all [--purge]
  cmd-installer.sh list
  cmd-installer.sh self-install
  cmd-installer.sh help

Commands are installed into ~/.local/cmd-installer/bin, which is added
to your PATH through your shell startup files.

Example:
  cmd-installer.sh gidcraft_mcp_up "gridcraft --control 6969"
EOF
}

require_not_root() {
	if [ "$(id -u)" -eq 0 ]; then
		die 2 "do not run as root; $PROG installs into your own home folder"
	fi
}

# Name: starts with a letter or digit, then letters, digits, '.', '_', '-'.
validate_name() {
	case "$1" in
	'') die "name must not be empty" ;;
	[!A-Za-z0-9]*) die "invalid name '$1': must start with a letter or digit" ;;
	*[!A-Za-z0-9._-]*) die "invalid name '$1': use only letters, digits, '.', '_' and '-'" ;;
	esac
}

# A file is ours when its second line is the marker.
is_managed() {
	[ -f "$1" ] && [ "$(sed -n 2p "$1")" = "$MARKER" ]
}

# Print the stored command of a wrapper (line 4 onward, without the "$@").
wrapper_command() {
	text=$(sed -n '4,$p' "$1")
	printf '%s\n' "${text% \"\$@\"}"
}

path_has_bin() {
	case ":$PATH:" in
	*":$BIN_DIR:"*) return 0 ;;
	*) return 1 ;;
	esac
}

# ---------------------------------------------------------------- setup

write_env_file() {
	cat >"$ENV_FILE" <<'EOF'
# Added by cmd-installer. Puts its bin folder on PATH (only once).
case ":$PATH:" in
  *":$HOME/.local/cmd-installer/bin:"*) ;;
  *) PATH="$HOME/.local/cmd-installer/bin:$PATH"; export PATH ;;
esac
EOF
}

# Append the source block to a startup file, unless it is already there.
add_block() {
	if [ -f "$1" ] && grep -qxF "$BLOCK_BEGIN" "$1"; then
		return 0
	fi
	{
		printf '\n%s\n' "$BLOCK_BEGIN"
		# shellcheck disable=SC2016 # $HOME must stay literal in the file
		printf '%s\n' '[ -f "$HOME/.local/cmd-installer/env.sh" ] && . "$HOME/.local/cmd-installer/env.sh"'
		printf '%s\n' "$BLOCK_END"
	} >>"$1"
	BLOCKS_ADDED="$BLOCKS_ADDED ${1#"$HOME"/}"
}

# Remove the source block (and the blank line before it) from a startup file.
remove_block() {
	[ -f "$1" ] || return 0
	grep -qxF "$BLOCK_BEGIN" "$1" || return 0
	tmp=$(mktemp "${TMPDIR:-/tmp}/$PROG.XXXXXX")
	awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
		skip { if ($0 == e) skip = 0; next }
		$0 == b { skip = 1; pending = 0; next }
		pending { print ""; pending = 0 }
		$0 == "" { pending = 1; next }
		{ print }
		END { if (pending) print "" }
	' "$1" >"$tmp"
	# cat (not mv) keeps the file's permissions and any symlink.
	cat "$tmp" >"$1"
	rm -f "$tmp"
	info "Removed PATH block from ~/${1#"$HOME"/}"
}

bootstrap() {
	BLOCKS_ADDED=""
	mkdir -p "$BIN_DIR"
	[ -f "$ENV_FILE" ] || write_env_file
	add_block "$HOME/.bashrc"
	add_block "$HOME/.profile"
	[ -f "$HOME/.bash_profile" ] && add_block "$HOME/.bash_profile"
	[ -f "$HOME/.zshrc" ] && add_block "$HOME/.zshrc"
	if [ -n "$BLOCKS_ADDED" ]; then
		info "Added $BIN_DIR to PATH in:$BLOCKS_ADDED"
	fi
}

path_hint() {
	if ! path_has_bin; then
		info "Open a new terminal, or run:  . ~/.local/cmd-installer/env.sh"
	fi
}

# Write stdin to $1 all at once (temp file in the same folder + mv).
atomic_write() {
	dest=$1
	tmp=$(mktemp "$BIN_DIR/.tmp.XXXXXX")
	if ! cat >"$tmp" || ! chmod 755 "$tmp" || ! mv -f "$tmp" "$dest"; then
		rm -f "$tmp"
		die 2 "could not write $dest"
	fi
}

# ---------------------------------------------------------------- commands

cmd_install() {
	force=0
	name=""
	command=""
	nargs=0
	for arg in "$@"; do
		if [ "$arg" = "--force" ] || [ "$arg" = "-f" ]; then
			force=1
			continue
		fi
		nargs=$((nargs + 1))
		case $nargs in
		1) name=$arg ;;
		2) command=$arg ;;
		*) die "too many arguments; put the whole command in quotes" ;;
		esac
	done
	[ "$nargs" -eq 2 ] || { usage >&2; exit 1; }

	validate_name "$name"
	[ "$name" = "$PROG" ] && die "'$PROG' is a reserved name"
	case "$command" in
	*[![:space:]]*) ;;
	*) die "command must not be empty" ;;
	esac

	bootstrap
	target="$BIN_DIR/$name"

	if [ -e "$target" ]; then
		is_managed "$target" ||
			die "$target exists and was not created by $PROG; not touching it"
		[ "$force" -eq 1 ] ||
			die "'$name' is already installed; use --force to replace it"
	fi

	existing=$(command -v "$name" 2>/dev/null || true)
	if [ -n "$existing" ] && [ "$existing" != "$target" ]; then
		case "$existing" in
		/*) warn "'$name' already exists at $existing; whichever comes first on PATH wins" ;;
		*) warn "'$name' is also a shell builtin, alias or function; that will take priority" ;;
		esac
	fi

	{
		printf '#!/bin/sh\n'
		printf '%s\n' "$MARKER"
		printf '# installed: %s\n' "$(date +%Y-%m-%d)"
		printf '%s "$@"\n' "$command"
	} | atomic_write "$target"

	info "Installed '$name' -> $command"
	path_hint
}

cmd_uninstall() {
	all=0
	purge=0
	name=""
	for arg in "$@"; do
		case "$arg" in
		--all) all=1 ;;
		--purge) purge=1 ;;
		-*) die "unknown option '$arg'" ;;
		*)
			[ -z "$name" ] || die "uninstall takes one name (or --all)"
			name=$arg
			;;
		esac
	done

	if [ "$purge" -eq 1 ] && [ "$all" -eq 0 ]; then
		die "--purge only works together with --all"
	fi
	if [ "$all" -eq 1 ]; then
		[ -z "$name" ] || die "use either a name or --all, not both"
		uninstall_all "$purge"
		return
	fi
	[ -n "$name" ] || { usage >&2; exit 1; }

	validate_name "$name"
	target="$BIN_DIR/$name"
	[ -e "$target" ] || die "'$name' is not installed"
	if [ "$name" = "$PROG" ]; then
		die "use 'uninstall --all --purge' to remove $PROG itself"
	fi
	is_managed "$target" || die "$target was not created by $PROG; not touching it"
	rm -f "$target"
	info "Uninstalled '$name'"
}

uninstall_all() {
	purge=$1
	count=0
	if [ -d "$BIN_DIR" ]; then
		for f in "$BIN_DIR"/*; do
			[ -f "$f" ] || continue
			[ "${f##*/}" = "$PROG" ] && continue
			if is_managed "$f"; then
				rm -f "$f"
				count=$((count + 1))
			fi
		done
	fi
	info "Uninstalled $count command(s)"

	[ "$purge" -eq 1 ] || return 0

	rm -f "$SELF_PATH" "$ENV_FILE"
	for rc in .bashrc .profile .bash_profile .zshrc; do
		remove_block "$HOME/$rc"
	done
	rmdir "$BIN_DIR" 2>/dev/null || true
	rmdir "$CI_HOME" 2>/dev/null || true
	if [ -d "$CI_HOME" ]; then
		warn "kept $CI_HOME because it still has files $PROG did not create"
	else
		info "Removed $CI_HOME"
	fi
}

cmd_list() {
	found=0
	if [ -d "$BIN_DIR" ]; then
		for f in "$BIN_DIR"/*; do
			[ -f "$f" ] || continue
			[ "${f##*/}" = "$PROG" ] && continue
			is_managed "$f" || continue
			printf '%s -> %s\n' "${f##*/}" "$(wrapper_command "$f")"
			found=1
		done
	fi
	[ "$found" -eq 1 ] || info "No commands installed."
}

cmd_self_install() {
	src=$0
	[ -f "$src" ] || die 2 "cannot find this script's file ($src)"
	bootstrap
	if [ "$src" -ef "$SELF_PATH" ]; then
		info "$PROG is already self-installed at $SELF_PATH"
		return 0
	fi
	atomic_write "$SELF_PATH" <"$src"
	info "Installed $PROG to $SELF_PATH"
	path_hint
}

# ---------------------------------------------------------------- main

main() {
	case "${1:-}" in
	'')
		usage >&2
		exit 1
		;;
	help | -h | --help)
		usage
		exit 0
		;;
	esac

	require_not_root

	case "$1" in
	install) shift; cmd_install "$@" ;;
	uninstall) shift; cmd_uninstall "$@" ;;
	list) shift; cmd_list ;;
	self-install) shift; cmd_self_install ;;
	-*) die "unknown option '$1' (see: $PROG help)" ;;
	*) cmd_install "$@" ;;
	esac
}

main "$@"
