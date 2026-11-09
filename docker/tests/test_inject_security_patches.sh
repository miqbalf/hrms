#!/bin/bash
# Test docker/assets/inject_security_patches.sh against a fresh upstream
# frappe/hrms checkout (the code production actually runs).
#
# Usage: docker/tests/test_inject_security_patches.sh [UPSTREAM_REF]
#   UPSTREAM_REF defaults to the tag pinned in docker-compose.coolify.yml.
# Needs: git, python3, network access to github.com. Run on a test host,
# not on production.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/docker/assets/inject_security_patches.sh"
REF="${1:-$(sed -n 's/^ *HRMS_UPSTREAM_REF=//p' "$REPO/docker-compose.coolify.yml")}"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }

echo "== upstream ref: $REF"
git clone -q --depth 1 --branch "$REF" https://github.com/frappe/hrms.git "$WORK/bench/apps/hrms" 2>/dev/null
check "upstream clone of $REF" '[ -d "$WORK/bench/apps/hrms/hrms" ]'
cd "$WORK/bench" || exit 1
git -C apps/hrms rev-parse HEAD

echo "== bash -n"
check "injector syntax" 'bash -n "$SCRIPT"'

echo "== first run"
out1="$(bash "$SCRIPT" apps/hrms)"; rc1=$?
echo "$out1"
check "first run exits 0" '[ $rc1 -eq 0 ]'
check "first run applies 12 patches, verifies M4, skips none" \
  'echo "$out1" | grep -q "12 applied, 0 already present, 1 verified upstream, 0 skipped"'
check "no WARNING on first run" '! echo "$out1" | grep -q WARNING'
count=$(git -C apps/hrms grep -c "TREEO-SEC" | awk -F: '{s+=$2} END {print s}')
check "TREEO-SEC markers present (got $count)" '[ "$count" -ge 12 ]'
check "patched files compile" 'python3 -m py_compile $(git -C apps/hrms diff --name-only | sed "s#^#apps/hrms/#")'
git -C apps/hrms diff --stat
state1="$(git -C apps/hrms diff | sha256sum)"

echo "== second run (idempotency)"
out2="$(bash "$SCRIPT" apps/hrms)"; rc2=$?
echo "$out2"
check "second run exits 0" '[ $rc2 -eq 0 ]'
check "second run applies nothing" 'echo "$out2" | grep -q "0 applied, 12 already present, 1 verified upstream, 0 skipped"'
check "second run leaves tree unchanged" '[ "$(git -C apps/hrms diff | sha256sum)" = "$state1" ]'

echo "== missing anchor"
git -C apps/hrms checkout -q -- .
sed -i 's/^def get_workflow(/def get_workflow_renamed(/' apps/hrms/hrms/api/__init__.py
out3="$(bash "$SCRIPT" apps/hrms)"; rc3=$?
echo "$out3" | grep -E "WARNING|Security patches"
check "missing anchor exits 0" '[ $rc3 -eq 0 ]'
check "missing anchor logs WARNING for M2a" 'echo "$out3" | grep -q "WARNING: security patch M2a"'
check "other patches still applied" 'echo "$out3" | grep -q "11 applied"'

echo "== G1 block changed upstream"
git -C apps/hrms checkout -q -- .
sed -i 's/^\tglobal country_info$/\tglobal country_info  # upstream edit/' apps/hrms/hrms/utils/__init__.py
out5="$(bash "$SCRIPT" apps/hrms)"; rc5=$?
echo "$out5" | grep -E "WARNING|Security patches"
check "changed G1 block exits 0" '[ $rc5 -eq 0 ]'
check "changed G1 block logs WARNING for G1" 'echo "$out5" | grep -q "WARNING: security patch G1"'
check "changed G1 block leaves get_country untouched" '! grep -q "TREEO-SEC G1" apps/hrms/hrms/utils/__init__.py'

echo "== missing app dir"
out4="$(bash "$SCRIPT" "$WORK/does-not-exist")"; rc4=$?
echo "$out4"
check "missing app dir exits 0 with WARNING" '[ $rc4 -eq 0 ] && echo "$out4" | grep -q WARNING'

[ $fail -eq 0 ] && echo "ALL PASS" || echo "SOME TESTS FAILED"
exit $fail
