#!/bin/sh
# Test cases for cmd-installer.sh. Runs in a fresh temporary HOME, so the
# real user's startup files are never touched.
# Usage: tests/cases.sh /path/to/cmd-installer.sh

set -u

SCRIPT=${1:?usage: cases.sh /path/to/cmd-installer.sh}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cmd-installer-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

HOME="$WORK/home"
mkdir -p "$HOME"
export HOME
PATH=/usr/local/bin:/usr/bin:/bin
export PATH
unset ENV BASH_ENV 2>/dev/null || true

CI_HOME="$HOME/.local/cmd-installer"
BIN="$CI_HOME/bin"
BEGIN="# >>> cmd-installer >>>"

pass=0
fail=0

ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
nok() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }

# check "description" command...   -> passes when the command succeeds
check() {
	desc=$1; shift
	if "$@" >"$WORK/out" 2>&1; then ok "$desc"; else nok "$desc" "$(head -3 "$WORK/out")"; fi
}
# refuse "description" command...  -> passes when the command fails
refuse() {
	desc=$1; shift
	if "$@" >"$WORK/out" 2>&1; then nok "$desc" "expected failure, got success"; else ok "$desc"; fi
}
# same "description" expected actual
same() {
	if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "expected [$2], got [$3]"; fi
}

ci() { sh "$SCRIPT" "$@"; }
login() { bash -lc "$1" 2>/dev/null; }
inter() { bash -ic "$1" 2>/dev/null; }
blocks_in() { grep -cxF "$BEGIN" "$1" 2>/dev/null || true; }

printf 'Target: %s | /bin/sh -> %s | uid %s\n' \
	"$(. /etc/os-release 2>/dev/null && printf '%s' "$PRETTY_NAME")" \
	"$(readlink -f /bin/sh)" "$(id -u)"

# Simulate a RHEL/Fedora-style home with existing .bash_profile and .zshrc.
: >"$HOME/.bash_profile"
: >"$HOME/.zshrc"

echo "-- first install and setup"
check "short form install works" ci hello "echo hello-from-wrapper"
check "bin folder created" test -d "$BIN"
check "env.sh created" test -f "$CI_HOME/env.sh"
for rc in .bashrc .profile .bash_profile .zshrc; do
	same "PATH block added to $rc" 1 "$(blocks_in "$HOME/$rc")"
done
check "wrapper is executable" test -x "$BIN/hello"

echo "-- PATH works in new shells"
same "bash login shell runs it" "hello-from-wrapper" "$(login hello)"
same "bash interactive shell runs it" "hello-from-wrapper" "$(inter hello)"
same "sh login shell (~/.profile) runs it" "hello-from-wrapper" \
	"$(HOME=$HOME sh -lc hello 2>/dev/null)"
same "PATH entry is not duplicated" 1 \
	"$(login '. "$HOME/.local/cmd-installer/env.sh"; echo "$PATH"' | tr ':' '\n' | grep -cxF "$BIN")"

echo "-- install behaviour"
check "install subcommand works" ci install say "echo said:"
same "extra arguments pass through" "said: a b" "$(login 'say a b')"
same "PATH block still added only once" 1 "$(blocks_in "$HOME/.bashrc")"

# shellcheck disable=SC2016 # literal $ on purpose
QCMD='printf "%s|%s\n" "$HOME" '"'"'$literal'"'"
check "install command with quotes and \$" ci install qt "$QCMD"
same "command stored exactly as given" "$QCMD \"\$@\"" "$(sed -n 4p "$BIN/qt")"
same "\$HOME expands at run time, not install time" "$HOME|\$literal" "$(login qt)"

for bad in "-x" "a/b" "a b" ".hidden" "_x" "cmd-installer"; do
	refuse "rejects bad name '$bad'" ci install "$bad" "echo x"
done
refuse "rejects empty name" ci install "" "echo x"
refuse "rejects empty command" ci install foo ""
refuse "rejects blank command" ci install foo "   "
refuse "rejects too many arguments" ci install foo echo hi

refuse "duplicate install refused" ci install hello "echo second"
check "duplicate install with --force works" ci install hello "echo second" --force
same "--force replaced the command" "second" "$(login hello)"

printf '#!/bin/sh\necho manual\n' >"$BIN/manual"
chmod 755 "$BIN/manual"
refuse "won't overwrite a file it didn't create (even --force)" ci install manual "echo x" --force
same "unmanaged file left intact" "manual" "$(login manual)"

echo "-- root is refused"
mkdir -p "$WORK/fakeroot"
printf '#!/bin/sh\necho 0\n' >"$WORK/fakeroot/id"
chmod 755 "$WORK/fakeroot/id"
PATH="$WORK/fakeroot:$PATH" sh "$SCRIPT" list >/dev/null 2>&1
same "running as root exits with code 2" 2 "$?"

echo "-- list"
ci list >"$WORK/list" 2>&1
check "list shows hello" grep -qxF "hello -> echo second" "$WORK/list"
check "list shows say" grep -qxF "say -> echo said:" "$WORK/list"
check "list shows stored quotes exactly" grep -qxF "qt -> $QCMD" "$WORK/list"
refuse "list hides unmanaged files" grep -q '^manual' "$WORK/list"

echo "-- self-install"
check "self-install works" ci self-install
check "self-installed copy is executable" test -x "$BIN/cmd-installer"
check "cmd-installer runs from PATH" login "cmd-installer list"
check "self-install again from installed copy is fine" login "cmd-installer self-install"
refuse "list hides cmd-installer itself" grep -q '^cmd-installer' "$WORK/list"

echo "-- uninstall"
check "uninstall one name" ci uninstall say
check "wrapper removed" test ! -e "$BIN/say"
refuse "removed command no longer found" login "command -v say"
refuse "uninstall of missing name fails" ci uninstall say
refuse "uninstall of unmanaged file refused" ci uninstall manual
refuse "uninstall of cmd-installer itself refused" ci uninstall cmd-installer
refuse "--purge without --all refused" ci uninstall --purge

check "uninstall --all works" ci uninstall --all
check "--all removed hello" test ! -e "$BIN/hello"
check "--all removed qt" test ! -e "$BIN/qt"
check "--all kept unmanaged file" test -f "$BIN/manual"
check "--all kept self-installed copy" test -f "$BIN/cmd-installer"
check "uninstall --all on empty folder is fine" ci uninstall --all

echo "-- purge"
check "install again before purge" ci install back "echo back"
check "--purge with an unmanaged file left over" ci uninstall --all --purge
check "unmanaged file still there" test -f "$BIN/manual"
check "env.sh removed" test ! -e "$CI_HOME/env.sh"
check "self-installed copy removed" test ! -e "$BIN/cmd-installer"
for rc in .bashrc .profile .bash_profile .zshrc; do
	same "PATH block removed from $rc" 0 "$(blocks_in "$HOME/$rc")"
done
rm -f "$BIN/manual"
check "--purge again once folder is clean" ci uninstall --all --purge
check "cmd-installer folder fully removed" test ! -e "$CI_HOME"
same ".bash_profile back to empty" "" "$(cat "$HOME/.bash_profile")"

echo "-- reinstall after purge"
check "install works again after purge" ci hello "echo again"
same "and runs" "again" "$(login hello)"

echo "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
