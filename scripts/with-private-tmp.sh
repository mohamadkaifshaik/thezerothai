#!/usr/bin/env bash
# scripts/with-private-tmp.sh <command> [args...]
#
# Runs <command> with a private, per-run temp directory and removes it afterwards. Every `make` target
# that launches the Firebase Emulator Suite goes through this (emulators, test-int, dev); run any raw
# `firebase emulators:*` call the same way: `bash scripts/with-private-tmp.sh firebase emulators:exec ...`.
#
# Why: the Storage emulator (hosted in the firebase-tools Node process) keeps its blobs in
# `os.tmpdir()/firebase/storage/blobs`, a directory shared by every suite on the machine, whatever ports
# and project ids they use. A second suite starting or stopping wipes it, and the first one crashes
# mid-upload (`ENOENT ... Temp\firebase\storage\blobs\<id>` at Persistence.appendBytes, then "An
# unexpected error has occurred", and the Auth emulator refuses connections). With a private temp
# directory per run, two suites cannot touch each other's files. docs/runbooks/emulator-collisions.md.
#
# How: mktemp -d under the caller's temp dir, then TEMP, TMP and TMPDIR point at it for <command> and
# everything it starts (emulators, go test, go run, flutter run), and only for those: the caller's own
# environment is untouched. Node's os.tmpdir() reads TMP/TEMP on Windows and TMPDIR on POSIX, so all
# three are set. On Windows (Git Bash) TEMP and TMP get the native form (C:\...) via cygpath, because
# native programs do not translate /c/... paths; TMPDIR keeps the POSIX form for bash tools. (On POSIX
# the JVM ignores TMPDIR and uses /tmp; the shared state that broke runs is the Node one.)
#
# The directory is removed when <command> ends, however it ends (exit, Ctrl+C, SIGTERM); removal is best
# effort and never changes the exit status: on Windows a leftover emulator java.exe can still hold files
# open for a moment, in which case the path is printed and left for the OS to clean up.
set -uo pipefail

if [ "$#" -eq 0 ]; then
	echo "usage: $0 <command> [args...]" >&2
	exit 2
fi

parent="${TMPDIR:-/tmp}"
if ! dir="$(mktemp -d "${parent%/}/dzeroth-emu.XXXXXX")" || [ -z "$dir" ] || [ ! -d "$dir" ]; then
	echo "with-private-tmp: cannot create a private temp directory under $parent" >&2
	exit 1
fi

native="$dir"
if command -v cygpath >/dev/null 2>&1; then
	native="$(cygpath -w "$dir")"
fi

cleanup() {
	trap - EXIT INT TERM
	local attempt
	for attempt in 1 2 3; do
		rm -rf "$dir" 2>/dev/null
		[ ! -e "$dir" ] && return 0
		sleep 1
	done
	echo "with-private-tmp: could not remove $dir (a leftover emulator process may still hold files open); safe to delete it later" >&2
	return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export TMPDIR="$dir" TEMP="$native" TMP="$native"

rc=0
"$@" || rc=$?
exit "$rc"
