#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$("$PROJECT_DIR/scripts/build-dev.sh")"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
checks=0

expect_usage_error() {
    local expected="$1" status=0 message
    shift
    "$TOOL" "$@" > "$TEMP_DIR/stdout" 2> "$TEMP_DIR/stderr" || status=$?
    message="$(< "$TEMP_DIR/stderr")"
    if [[ "$status" != 64 || -s "$TEMP_DIR/stdout" || "$message" != *"$expected"* || "$message" != *'Usage: scripts/dev.sh'* ]]; then
        printf 'Expected exit 64 and a usage error containing %s, got exit %s with arguments:' "$expected" "$status" >&2
        printf ' %q' "$@" >&2
        printf '\n%s\n' "$message" >&2
        exit 1
    fi
    checks=$((checks + 1))
}

expect_usage_error 'A development command is required.'
expect_usage_error 'Unknown development command: --unknown' --unknown
expect_usage_error 'Unknown development command: previews' previews
expect_usage_error 'Unexpected argument after --smoke-test' --smoke-test extra
expect_usage_error 'Unexpected argument after --smoke-test' --smoke-test --live-display-test
for command in --live-display-test --render-preview --render-timer-previews --render-documentation-previews \
    --render-quick-previews --render-style-previews; do
    expect_usage_error "$command requires" "$command"
    expect_usage_error "$command requires" "$command" ''
    expect_usage_error "$command requires" "$command" --smoke-test
    expect_usage_error "$command requires" "$command" -x
    expect_usage_error 'Unexpected argument after' "$command" "$TEMP_DIR/unused-output" extra
done
if [[ -e "$TEMP_DIR/unused-output" ]]; then
    printf 'Invalid development arguments created output.\n' >&2
    exit 1
fi
printf 'Development command validation passed (%s cases).\n' "$checks"
