#!/bin/bash
# A tiny assertion library, so the test suite needs nothing but bash and the
# coreutils that the scripts under test already depend on. No downloads and no
# network access, which keeps the whole suite free to run on every push.

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST="(none)"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

it() {
  CURRENT_TEST="$1"
  TESTS_RUN=$((TESTS_RUN + 1))
}

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "  FAIL: $CURRENT_TEST"
  while [[ $# -gt 0 ]]; do
    echo "        $1"
    shift
  done
}

pass_note() {
  echo "  ok:   $CURRENT_TEST"
}

assert_eq() {
  local expected="$1" actual="$2" what="${3:-}"
  if [[ "$expected" == "$actual" ]]; then
    pass_note
  else
    fail "${what:+$what}" "expected: [$expected]" "actual:   [$actual]"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" what="${3:-}"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_note
  else
    fail "${what:+$what}" "expected to contain: [$needle]" "in: [$haystack]"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" what="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_note
  else
    fail "${what:+$what}" "expected NOT to contain: [$needle]"
  fi
}

assert_file_contains() {
  local file="$1" needle="$2" what="${3:-}"
  if grep -qF -- "$needle" "$file"; then
    pass_note
  else
    fail "${what:+$what}" "expected $file to contain: [$needle]"
  fi
}

assert_file_not_contains() {
  local file="$1" needle="$2" what="${3:-}"
  if grep -qF -- "$needle" "$file"; then
    fail "${what:+$what}" "expected $file NOT to contain: [$needle]"
  else
    pass_note
  fi
}

# Run a command, expecting it to succeed.
assert_ok() {
  local what="$1"
  shift
  local output status
  output="$("$@" 2>&1)" && status=0 || status=$?
  if [[ $status -eq 0 ]]; then
    pass_note
  else
    fail "$what" "command failed with status $status: $*" "$output"
  fi
}

# Run a command, expecting it to fail.
assert_not_ok() {
  local what="$1"
  shift
  local output status
  output="$("$@" 2>&1)" && status=0 || status=$?
  if [[ $status -ne 0 ]]; then
    pass_note
  else
    fail "$what" "expected failure but the command succeeded: $*" "$output"
  fi
}

test_summary() {
  echo ""
  if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "$(basename "$0"): $TESTS_RUN assertions, all passed"
    return 0
  fi
  echo "$(basename "$0"): $TESTS_RUN assertions, $TESTS_FAILED FAILED"
  return 1
}
