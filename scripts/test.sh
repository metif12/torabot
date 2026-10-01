#!/bin/sh
# Runs the unit tests one file at a time.
#
# Each file is built into its own binary and executed. A single `v test` over
# the directory builds the files concurrently, which on some toolchains fails
# while compiling libgc and reports only "exec failed (SetHandleInformation)".
# Splitting the runs keeps a failure attributable to one file.

set -eu

PROJECT_ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

# VEXE matters when the compiler was downloaded as a release archive: it has no
# vlib beside it, and without VEXE every build fails with
# "builtin/ not included on module lookup path".
V="${V:-${VEXE:-v}}"
BIN="${TMPDIR:-/tmp}/torabot-test.$$"

TESTS='torabot/http_test.v torabot/discord_test.v torabot/args_test.v torabot/inflate_test.v'

failed=0

for t in $TESTS; do
	name="$(basename "$t" .v)"
	echo "==> $name"
	if ! "$V" -o "$BIN" "$PROJECT_ROOT/$t"; then
		echo "    build FAILED: $t" >&2
		failed=$((failed + 1))
		continue
	fi
	if ! "$BIN"; then
		echo "    run FAILED: $t" >&2
		failed=$((failed + 1))
		continue
	fi
	echo "    ok"
done

rm -f "$BIN"

if [ "$failed" -ne 0 ]; then
	echo "$failed test file(s) failed" >&2
	exit 1
fi

echo "all test files passed"