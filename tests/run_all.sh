#!/bin/bash
# Run the whole suite. Needs nothing but bash and coreutils, makes no network
# requests and downloads nothing, so it is cheap enough to run on every push.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

failed=0
for test_file in test_*.sh; do
  echo "########## $test_file"
  if bash "$test_file"; then
    echo ""
  else
    failed=$((failed + 1))
    echo ""
  fi
done

if [[ $failed -eq 0 ]]; then
  echo "All test files passed."
  exit 0
fi

echo "$failed test file(s) FAILED."
exit 1
