#!/bin/bash
# Test docker/assets/inject_security_patches.sh against a fresh upstream
# frappe/hrms checkout (the code production actually runs).
#
# Usage: docker/tests/test_inject_security_patches.sh [UPSTREAM_REF]
#   UPSTREAM_REF defaults to the tag pinned in docker-compose.coolify.yml.
# Needs: git, python3, network access to github.com. Run on a test host,
# not on production. Optional: pyflakes, node (index.js checks) and
# VUE_SFC_DIR=<dir with node_modules/@vue/compiler-sfc> (roster template compile).
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
check "first run applies 45 patches, verifies M4, skips none" \
  'echo "$out1" | grep -q "45 applied, 0 already present, 1 verified upstream, 0 skipped"'
check "no WARNING on first run" '! echo "$out1" | grep -q WARNING'
count=$(git -C apps/hrms grep -c "TREEO-SEC" | awk -F: '{s+=$2} END {print s}')
check "TREEO-SEC markers present (got $count)" '[ "$count" -ge 45 ]'
check "patched files compile" 'python3 -m py_compile $(git -C apps/hrms diff --name-only -- "*.py" | sed "s#^#apps/hrms/#")'
if python3 -m pyflakes --version >/dev/null 2>&1; then
  # only names the patches could break; upstream has its own unrelated lint noise
  check "pyflakes: no undefined names in patched files" \
    '! python3 -m pyflakes $(git -C apps/hrms diff --name-only -- "*.py" | sed "s#^#apps/hrms/#") | grep -i "undefined name"'
else
  echo "SKIP: pyflakes not installed (pip install pyflakes to enable)"
fi
git -C apps/hrms diff --stat

echo "== frontend / template patches (built by bench build after the injector)"
H=apps/hrms
check "M18a feedback text escaped" 'grep -qF "{{ frappe.utils.escape_html(strip_html(feedback_history[i].feedback)) }}" $H/hrms/public/js/templates/feedback_history.html'
check "M18 no raw feedback/reviewer interpolation left" \
  '! grep -qE "\{\{ (strip_html\()?feedback_history\[i\]\.(feedback|reviewer_name|reviewer_designation)" $H/hrms/public/js/templates/feedback_history.html'
check "M19 roster has no v-html left in MonthViewTable" '! grep -q "v-html" $H/roster/src/components/MonthViewTable.vue'
check "M19 holiday description rendered with v-text" 'grep -q "v-text=\"String(events.data\[employee.name\]\[day.date\].description" $H/roster/src/components/MonthViewTable.vue'
check "M20a team updates sanitises and scopes" 'grep -q "sanitize_html(d.content" $H/hrms/hr/page/team_updates/team_updates.py && grep -q "Daily Work Summary Group User" $H/hrms/hr/page/team_updates/team_updates.py'
check "M20b sender name escaped" 'grep -qF "{%= frappe.utils.escape_html(by) %}" $H/hrms/hr/page/team_updates/team_update_row.html'
check "M22b job card no longer navigates to raw id" '! grep -qF "window.location.href = this.id;" $H/hrms/www/jobs/index.js'
if command -v node >/dev/null 2>&1; then
  check "M22b index.js parses (node --check)" 'node --check $H/hrms/www/jobs/index.js'
  check "M22b patched href expression yields same-site paths" 'node - "$H/hrms/www/jobs/index.js" <<"JS"
const src = require("fs").readFileSync(process.argv[2], "utf8");
const m = src.match(/window\.location\.href = (.*); \/\/ TREEO-SEC M22b/);
if (!m) process.exit(1);
const href = new Function("id", "return " + m[1].replace("this.id", "id"));
const got = ["javascript:alert(1)", " //evil.com", "\\\\evil", "jobs/a/b"].map(href).join("|");
process.exit(got === "/javascript:alert(1)|/evil.com|/evil|/jobs/a/b" ? 0 : 1);
JS'
  if [ -n "${VUE_SFC_DIR:-}" ] && [ -d "$VUE_SFC_DIR/node_modules/@vue/compiler-sfc" ]; then
    check "M19 MonthViewTable.vue template compiles (@vue/compiler-sfc)" 'NODE_PATH="$VUE_SFC_DIR/node_modules" node - "$H/roster/src/components/MonthViewTable.vue" <<"JS"
const { parse, compileTemplate } = require("@vue/compiler-sfc");
const file = process.argv[2];
const { descriptor, errors } = parse(require("fs").readFileSync(file, "utf8"), { filename: file });
if (errors.length) { console.error(errors); process.exit(1); }
const out = compileTemplate({ source: descriptor.template.content, filename: file, id: "x",
  compilerOptions: { isTS: true, expressionPlugins: ["typescript"] } });
if (out.errors.length) { console.error(out.errors); process.exit(1); }
if (!/description/.test(out.code) || /innerHTML/.test(out.code)) process.exit(1);
JS'
  else
    echo "SKIP: VUE_SFC_DIR not set (dir with node_modules/@vue/compiler-sfc) - Vue compile check"
  fi
else
  echo "SKIP: node not installed (node --check of index.js)"
fi
check "M21b hooks register payroll scoping" 'grep -q "treeo_own_payroll" $H/hrms/hooks.py && python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" $H/hrms/hooks.py'

echo "== behaviour of pure-python patch logic"
check "M22a route check rejects schemes and //host, keeps paths" 'python3 - <<"PYT"
def bad(r):
    route = r.strip().replace("\\", "/")
    return ":" in route.split("/")[0] or route.startswith("//")
assert bad("javascript:alert(1)") and bad(" JavaScript:x") and bad("//evil.com") and bad("\\\\evil")
assert not bad("jobs/treeo/lead:-data") and not bad("jobs/treeo/engineer") and not bad("/jobs/x")
PYT'
check "M22a check is the one injected" 'grep -qF "if \":\" in route.split(\"/\")[0] or route.startswith(\"//\"):" $H/hrms/hr/doctype/job_opening/job_opening.py'
state1="$(git -C apps/hrms diff | sha256sum)"

echo "== second run (idempotency)"
out2="$(bash "$SCRIPT" apps/hrms)"; rc2=$?
echo "$out2"
check "second run exits 0" '[ $rc2 -eq 0 ]'
check "second run applies nothing" 'echo "$out2" | grep -q "0 applied, 45 already present, 1 verified upstream, 0 skipped"'
check "second run leaves tree unchanged" '[ "$(git -C apps/hrms diff | sha256sum)" = "$state1" ]'

echo "== missing anchor"
git -C apps/hrms checkout -q -- .
sed -i 's/^def get_workflow(/def get_workflow_renamed(/' apps/hrms/hrms/api/__init__.py
out3="$(bash "$SCRIPT" apps/hrms)"; rc3=$?
echo "$out3" | grep -E "WARNING|Security patches"
check "missing anchor exits 0" '[ $rc3 -eq 0 ]'
check "missing anchor logs WARNING for M2a" 'echo "$out3" | grep -q "WARNING: security patch M2a"'
check "other patches still applied" 'echo "$out3" | grep -q "44 applied"'
check "loud summary for 1 skipped" 'echo "$out3" | grep -q "SECURITY WARNING: 1 patches skipped"'

echo "== G1 block changed upstream"
git -C apps/hrms checkout -q -- .
sed -i 's/^\tglobal country_info$/\tglobal country_info  # upstream edit/' apps/hrms/hrms/utils/__init__.py
out5="$(bash "$SCRIPT" apps/hrms)"; rc5=$?
echo "$out5" | grep -E "WARNING|Security patches"
check "changed G1 block exits 0" '[ $rc5 -eq 0 ]'
check "changed G1 block logs WARNING for G1" 'echo "$out5" | grep -q "WARNING: security patch G1"'
check "changed G1 block leaves get_country untouched" '! grep -q "TREEO-SEC G1" apps/hrms/hrms/utils/__init__.py'

echo "== M21b needs the M21a helpers (cross-file prerequisite)"
git -C apps/hrms checkout -q -- .
printf "\n# TREEO-SEC M21a placeholder\n" >> apps/hrms/hrms/payroll/doctype/salary_slip/salary_slip.py
out7="$(bash "$SCRIPT" apps/hrms)"; rc7=$?
echo "$out7" | grep -E "M21|Security patches"
check "M21a already-marked file without helpers: M21b skipped, hooks untouched" \
  'echo "$out7" | grep -q "WARNING: security patch M21b" && ! grep -q "treeo_own_payroll" apps/hrms/hrms/hooks.py'

echo "== missing app dir"
out4="$(bash "$SCRIPT" "$WORK/does-not-exist")"; rc4=$?
echo "$out4"
check "missing app dir exits 1 with SECURITY ERROR" '[ $rc4 -eq 1 ] && echo "$out4" | grep -q "SECURITY ERROR"'

echo "== nothing applied or present"
mkdir -p "$WORK/empty-app/hrms"
out6="$(bash "$SCRIPT" "$WORK/empty-app")"; rc6=$?
echo "$out6" | grep -E "SECURITY|Security patches"
check "zero patches exits 1" '[ $rc6 -eq 1 ]'
check "zero patches prints SECURITY ERROR" 'echo "$out6" | grep -q "SECURITY ERROR: no security patch"'

[ $fail -eq 0 ] && echo "ALL PASS" || echo "SOME TESTS FAILED"
exit $fail
