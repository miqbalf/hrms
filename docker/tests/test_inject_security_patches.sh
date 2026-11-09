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
check "first run applies 69 patches, verifies M4 and M5h, skips none" \
  'echo "$out1" | grep -q "69 applied, 0 already present, 2 verified upstream, 0 skipped"'
check "no WARNING on first run" '! echo "$out1" | grep -q WARNING'
count=$(git -C apps/hrms grep -c "TREEO-SEC" | awk -F: '{s+=$2} END {print s}')
check "TREEO-SEC markers present (got $count)" '[ "$count" -ge 69 ]'
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
check "M21a payroll rule: only Administrator / HR Manager / HR User (SysMgr with own grant) see all" 'python3 - "$H/hrms/payroll/doctype/salary_slip/salary_slip.py" <<"PYT"
import sys, types
src = open(sys.argv[1]).read()
code = src[src.index("# TREEO-SEC M21a"):]
ROLES = {"admin@x": ["System Manager"], "sm_grant@x": ["System Manager", "Employee"],
         "hrm@x": ["HR Manager"], "hru@x": ["HR User", "Employee"],
         "emp@x": ["Employee"], "ess@x": ["Employee Self Service"], "sm@x": ["System Manager", "Employee"]}
PERMS = [{"role": "HR Manager", "read": 1}, {"role": "HR User", "read": 1},
         {"role": "Employee", "read": 1}, {"role": "Employee Self Service", "read": 1}]
OWNER = {"EMP-1": "emp@x", "EMP-2": "ess@x"}
perms_mod = types.ModuleType("frappe.permissions")
perms_mod.get_valid_perms = lambda dt, user: PERMS + ([{"role": "System Manager", "read": 1}] if user == "sm_grant@x" else [])
frappe = types.ModuleType("frappe"); frappe.permissions = perms_mod
sys.modules["frappe"] = frappe; sys.modules["frappe.permissions"] = perms_mod
frappe.get_roles = lambda user: ROLES.get(user, [])
frappe.session = types.SimpleNamespace(user="emp@x")
frappe.db = types.SimpleNamespace(get_value=lambda dt, n, f: OWNER.get(n), escape=lambda s: "\x27%s\x27" % s)
g = {"frappe": frappe}; exec(code, g)
class Doc(dict):
    doctype = "Salary Slip"
hp, qc = g["treeo_own_payroll_has_permission"], g["treeo_own_payroll_query_conditions"]
for u in ("Administrator", "hrm@x", "hru@x", "sm_grant@x"):
    assert hp(Doc(employee="EMP-1"), "read", u) is None and qc(u, "Salary Slip") == "", u
for u in ("emp@x", "ess@x", "sm@x", "nobody@x"):
    assert "`tabSalary Slip`.`employee` in (select `name` from `tabEmployee` where `user_id` = \x27%s\x27)" % u == qc(u, "Salary Slip"), u
    assert qc(u, "Salary Structure Assignment").startswith("`tabSalary Structure Assignment`.`employee`"), u
assert hp(Doc(employee="EMP-1"), "read", "emp@x") is None
assert hp(Doc(employee="EMP-2"), "read", "emp@x") is False
assert hp(Doc(employee="EMP-2"), "read", "ess@x") is None
assert hp(Doc(employee="EMP-1"), "read", "ess@x") is False
assert hp(Doc(employee="EMP-1"), "print", "sm@x") is False
assert hp(Doc(), "read", "emp@x") is False
PYT'
check "M22a route check rejects schemes and //host, keeps paths" 'python3 - <<"PYT"
def bad(r):
    route = r.strip().replace("\\", "/")
    return ":" in route.split("/")[0] or route.startswith("//")
assert bad("javascript:alert(1)") and bad(" JavaScript:x") and bad("//evil.com") and bad("\\\\evil")
assert not bad("jobs/treeo/lead:-data") and not bad("jobs/treeo/engineer") and not bad("/jobs/x")
PYT'
check "M22a check is the one injected" 'grep -qF "if \":\" in route.split(\"/\")[0] or route.startswith(\"//\"):" $H/hrms/hr/doctype/job_opening/job_opening.py'
check "M21a stored employee: a write cannot move another employee's record to oneself" 'python3 - "$H/hrms/payroll/doctype/salary_slip/salary_slip.py" <<"PYT"
import sys, types
src = open(sys.argv[1]).read()
code = src[src.index("# TREEO-SEC M21a"):]
OWNER = {"EMP-1": "emp@x", "EMP-2": "other@x"}
STORED = {"SS-1": "EMP-1", "SS-2": "EMP-2"}
perms_mod = types.ModuleType("frappe.permissions"); perms_mod.get_valid_perms = lambda dt, user: []
frappe = types.ModuleType("frappe"); frappe.permissions = perms_mod
sys.modules["frappe"] = frappe; sys.modules["frappe.permissions"] = perms_mod
frappe.get_roles = lambda user: ["Employee"]
frappe.session = types.SimpleNamespace(user="emp@x")
frappe.db = types.SimpleNamespace(get_value=lambda dt, n, f: (OWNER if dt == "Employee" else STORED).get(n))
g = {"frappe": frappe}; exec(code, g)
class Doc(dict):
    doctype = "Employee Benefit Application"
hp = g["treeo_own_payroll_has_permission"]
assert hp(Doc(employee="EMP-1", name="SS-1"), "write", "emp@x") is None
assert hp(Doc(employee="EMP-1", name="SS-2"), "write", "emp@x") is False
assert hp(Doc(employee="EMP-1", name="NEW-1"), "create", "emp@x") is None
PYT'
check "M21c / M12c hooks map the 9 payroll doctypes and Employee Checkin" 'python3 - "$H/hrms/hooks.py" <<"PYT"
import sys
g = {}; exec(open(sys.argv[1]).read(), g)
hp, qc = g["has_permission"], g["permission_query_conditions"]
P = "hrms.payroll.doctype.salary_slip.salary_slip.treeo_own_payroll"
for dt in ("Salary Slip", "Salary Structure Assignment", "Employee Promotion", "Employee Incentive",
           "Retention Bonus", "Salary Withholding", "Employee Benefit Application", "Employee Benefit Claim",
           "Employee Tax Exemption Declaration", "Employee Tax Exemption Proof Submission", "Employee Other Income"):
    assert hp[dt] == P + "_has_permission" and qc[dt] == P + "_query_conditions", dt
C = "hrms.hr.doctype.employee_checkin.employee_checkin.treeo_checkin_"
assert hp["Employee Checkin"] == C + "has_permission" and qc["Employee Checkin"] == C + "query_conditions"
assert len(qc) == 12 and len([d for d in hp if "treeo_stored_up_has_permission" not in str(hp[d])]) == 12
PYT'
check "M21c / M12c hook targets exist" 'grep -q "^def treeo_own_payroll_has_permission(" $H/hrms/payroll/doctype/salary_slip/salary_slip.py && grep -q "^def treeo_checkin_has_permission(" $H/hrms/hr/doctype/employee_checkin/employee_checkin.py && grep -q "^def treeo_checkin_query_conditions(" $H/hrms/hr/doctype/employee_checkin/employee_checkin.py'
check "M12b checkin rule: HR / System Manager / Administrator all, others own only (also before a change)" 'python3 - "$H/hrms/hr/doctype/employee_checkin/employee_checkin.py" <<"PYT"
import sys, types
src = open(sys.argv[1]).read()
code = src[src.index("# TREEO-SEC M12b"):]
ROLES = {"hrm@x": ["HR Manager"], "hru@x": ["HR User", "Employee"], "sm@x": ["System Manager"],
         "emp@x": ["Employee"], "ess@x": ["Employee Self Service"]}
OWNER = {"EMP-1": "emp@x", "EMP-2": "ess@x"}
STORED = {"CHK-1": "EMP-1", "CHK-2": "EMP-2"}
frappe = types.ModuleType("frappe")
frappe.get_roles = lambda user: ROLES.get(user, [])
frappe.session = types.SimpleNamespace(user="emp@x")
frappe.db = types.SimpleNamespace(get_value=lambda dt, n, f: (OWNER if dt == "Employee" else STORED).get(n),
                                  escape=lambda s: "\x27%s\x27" % s)
g = {"frappe": frappe}; exec(code, g)
hp, qc = g["treeo_checkin_has_permission"], g["treeo_checkin_query_conditions"]
for u in ("Administrator", "hrm@x", "hru@x", "sm@x"):
    assert hp({"employee": "EMP-2", "name": "CHK-2"}, "delete", u) is None and qc(u, "Employee Checkin") == "", u
for ptype in ("create", "read", "write", "delete"):
    assert hp({"employee": "EMP-1", "name": "CHK-1"}, ptype, "emp@x") is None, ptype
    assert hp({"employee": "EMP-2", "name": "CHK-2"}, ptype, "emp@x") is False, ptype
assert hp({"employee": "EMP-1"}, "create", "emp@x") is None
assert hp({"employee": "EMP-1", "name": "CHK-2"}, "write", "emp@x") is False  # move another checkin to self
assert hp({}, "create", "emp@x") is False
assert qc("emp@x", "Employee Checkin") == "`tabEmployee Checkin`.`employee` in (select `name` from `tabEmployee` where `user_id` = \x27emp@x\x27)"
PYT'
check "M23 own-payroll assertion: others only own employee, HR all; called after the M5e-g read check" 'python3 - "$H/hrms/payroll/doctype/salary_slip/salary_slip.py" "$H/hrms/payroll/doctype/employee_benefit_application/employee_benefit_application.py" <<"PYT"
import ast, sys, types
src = open(sys.argv[1]).read()
code = src[src.index("# TREEO-SEC M21a"):]
ROLES = {"hru@x": ["HR User"], "emp@x": ["Employee"], "sm@x": ["System Manager"]}
OWNER = {"EMP-1": "emp@x", "EMP-2": "x@x"}
class PermissionError(Exception): pass
def throw(msg, exc=Exception): raise exc(msg)
perms_mod = types.ModuleType("frappe.permissions"); perms_mod.get_valid_perms = lambda dt, user: []
frappe = types.ModuleType("frappe"); frappe.permissions = perms_mod
sys.modules["frappe"] = frappe; sys.modules["frappe.permissions"] = perms_mod
frappe.PermissionError, frappe.throw = PermissionError, throw
frappe.get_roles = lambda user: ROLES.get(user, [])
frappe.session = types.SimpleNamespace(user="emp@x")
frappe.db = types.SimpleNamespace(get_value=lambda dt, n, f: OWNER.get(n))
g = {"frappe": frappe, "_": lambda s: s}; exec(code, g)
a = g["treeo_assert_own_payroll"]
a("Employee Benefit Application", "EMP-1")
for u, emp in (("emp@x", "EMP-2"), ("sm@x", "EMP-2"), ("emp@x", None)):
    frappe.session.user = u
    try:
        a("Employee Benefit Application", emp); raise SystemExit("no PermissionError for %s %s" % (u, emp))
    except PermissionError:
        pass
frappe.session.user = "hru@x"; a("Employee Benefit Application", "EMP-2")
a("Employee Benefit Application", "EMP-2", user="Administrator")
tree = ast.parse(open(sys.argv[2]).read())
for fn in ("get_max_benefits", "get_max_benefits_remaining", "get_earning_components_max_benefits"):
    f = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == fn)
    s = [ast.unparse(x) for x in f.body[:3]]
    assert s[0] == "frappe.has_permission(\x27Employee\x27, \x27read\x27, employee, throw=True)", (fn, s)
    assert s[1] == "from hrms.payroll.doctype.salary_slip.salary_slip import treeo_assert_own_payroll", (fn, s)
    assert s[2] == "treeo_assert_own_payroll(\x27Employee Benefit Application\x27, employee)", (fn, s)
PYT'
check "M22c route / job_application_route / job_title character checks" 'python3 - "$H/hrms/hr/doctype/job_opening/job_opening.py" <<"PYT"
import sys, textwrap, types
lines = open(sys.argv[1]).read().split("\n")
i = next(k for k, l in enumerate(lines) if "TREEO-SEC M22c" in l)
j = next(k for k in range(i, len(lines)) if lines[k] == "\t\tself.update_closing_date()")
body = textwrap.indent(textwrap.dedent("\n".join(lines[i:j])), "\t")
frappe = types.SimpleNamespace(ValidationError=ValueError)
def throw(msg, exc=Exception): raise exc(msg)
frappe.throw = throw
g = {"frappe": frappe, "_": lambda s: s}; exec("def check(self):\n" + body, g)
def ok(route="jobs/treeo/engineer", jar=None, title="Engineer"):
    try:
        g["check"](types.SimpleNamespace(route=route, job_application_route=jar, job_title=title)); return True
    except ValueError:
        return False
assert ok() and ok(jar="jobs/apply") and ok(title="GIS & Data Engineer (O\x27Brien team)")
for r in ("jobs/x\" onmouseover=\"alert(1)", "jobs/x\x27y", "jobs/<b>", "jobs/a`b", "jobs/a b", "jobs/a\tb", "jobs//x", "x\n"):
    assert not ok(route=r), r
    assert not ok(jar=r), r
for t in ("x\" onmouseover=\"a", "<img src=x>", "a>b"):
    assert not ok(title=t), t
PYT'
if python3 -c "import jinja2" 2>/dev/null; then
  check "M22d-f job pages escape route / job_title / job_application_route (jinja render)" 'python3 - "$H" <<"PYT"
import subprocess, sys
from jinja2 import Environment
app = sys.argv[1]
env = Environment(autoescape=False)  # frappe.utils.jinja.get_jenv has no autoescape
evil = "x\" onmouseover=\"alert(1)"
def render(rel, start, n, ctx, ref=None):
    src = subprocess.run(["git", "-C", app, "show", "HEAD:" + rel], capture_output=True, text=True).stdout if ref else open(app + "/" + rel).read()
    lines = src.split("\n")
    i = next(k for k, l in enumerate(lines) if start in l)
    return env.from_string("\n".join(lines[i:i + n])).render(**ctx)
ctx = {"jo": {"route": evil, "job_title": evil, "employment_type": ""}}
new = render("hrms/www/jobs/index.html", "id=\"{{ jo.route", 13, ctx)
old = render("hrms/www/jobs/index.html", "id=\"{{ jo.route", 13, ctx, ref=True)
assert "onmouseover=\"alert" in old and "onmouseover=\"alert" not in new and "&#34;" in new, new
gctx = {"job_application_route": evil, "name": "a\"b"}
lines = open(app + "/hrms/templates/generators/job_opening.html").read().split("\n")
hrefs = [l for l in lines if "/new?job_title=" in l]
assert len(hrefs) == 2 and all("TREEO-SEC M22" in l for l in hrefs), hrefs
for l in hrefs:
    out = env.from_string(l).render(**gctx)
    assert "onmouseover=\"alert" not in out and "a&#34;b" in out, out
    assert env.from_string(l).render(job_application_route=None, name="HR-OPN-1").strip() == "href=\"/job_application/new?job_title=HR-OPN-1\"", l
PYT'
else
  echo "SKIP: jinja2 not installed (M22d-f render check)"
  check "M22d-f |e present" 'grep -q "jo.route|e" $H/hrms/www/jobs/index.html && [ $(grep -c "|e }}/new?job_title={{ name|e }}" $H/hrms/templates/generators/job_opening.html) -eq 2 ]'
fi
check "M24 send_exit_questionnaire needs email permission on every interview before anything is sent" 'python3 - "$H/hrms/hr/doctype/exit_interview/exit_interview.py" <<"PYT"
import sys, types
calls = []
class PermissionError(Exception): pass
class Reached(Exception): pass
def mod(name, **kw):
    m = types.ModuleType(name); m.__dict__.update(kw); sys.modules[name] = m; return m
def has_permission(dt, ptype, doc=None, throw=False):
    calls.append((dt, ptype, doc))
    if doc not in ALLOWED:
        raise PermissionError(doc)
    return True
def get_doc(*a):
    calls.append(("get_doc",) + a); raise Reached()
frappe = mod("frappe", _=lambda s: s, whitelist=lambda *a, **k: (lambda f: f), has_permission=has_permission,
             get_doc=get_doc, sendmail=lambda **k: calls.append("sendmail"), throw=lambda *a, **k: None,
             db=types.SimpleNamespace(get_value=lambda *a, **k: types.SimpleNamespace(
                 exit_questionnaire_web_form="w", exit_questionnaire_notification_template="t")))
mod("frappe.model"); mod("frappe.model.document", Document=object); mod("frappe.utils", get_link_to_form=str)
mod("erpnext"); mod("erpnext.setup"); mod("erpnext.setup.doctype"); mod("erpnext.setup.doctype.employee")
mod("erpnext.setup.doctype.employee.employee", get_employee_email=lambda e: "x@x")
g = {"__name__": "ei"}; exec(open(sys.argv[1]).read(), g)
ALLOWED = {"EI-1"}
try:
    g["send_exit_questionnaire"]([{"name": "EI-1"}, {"name": "EI-2"}]); raise SystemExit("no PermissionError")
except PermissionError:
    pass
assert calls == [("Exit Interview", "email", "EI-1"), ("Exit Interview", "email", "EI-2")], calls
calls.clear(); ALLOWED = {"EI-1", "EI-2"}
try:
    g["send_exit_questionnaire"]([{"name": "EI-1"}, {"name": "EI-2"}]); raise SystemExit("did not proceed")
except Reached:
    pass
assert calls[:2] == [("Exit Interview", "email", "EI-1"), ("Exit Interview", "email", "EI-2")] and calls[2][0] == "get_doc", calls
PYT'
check "M25 resume_link: only http(s) in Job Applicant and Employee Referral" 'python3 - "$H/hrms/hr/doctype/job_applicant/job_applicant.py" "$H/hrms/hr/doctype/employee_referral/employee_referral.py" <<"PYT"
import sys, textwrap, types
frappe = types.SimpleNamespace(ValidationError=ValueError)
def throw(msg, exc=Exception): raise exc(msg)
frappe.throw = throw
for path, mark in zip(sys.argv[1:], ("M25a", "M25b")):
    lines = open(path).read().split("\n")
    i = next(k for k, l in enumerate(lines) if "TREEO-SEC " + mark in l)
    assert lines[i - 1] == "\tdef validate(self):", path
    g = {"frappe": frappe, "_": lambda s: s}
    exec("def check(self):\n" + textwrap.indent(textwrap.dedent("\n".join(lines[i:i + 3])), "\t"), g)
    def ok(link):
        try:
            g["check"](types.SimpleNamespace(resume_link=link)); return True
        except ValueError:
            return False
    assert ok(None) and ok("") and ok("https://drive.google.com/x") and ok(" HTTP://cv.example/a.pdf"), path
    for bad in ("javascript:alert(1)", " JavaScript:x", "data:text/html,<script>", "//evil.com/x", "file:///etc/passwd"):
        assert not ok(bad), (path, bad)
PYT'
check "M26 upload_base64_file checks write permission before decoding" 'python3 - "$H/hrms/api/__init__.py" <<"PYT"
import ast, base64, sys, types
src = open(sys.argv[1]).read()
fn = next(n for n in ast.parse(src).body if isinstance(n, ast.FunctionDef) and n.name == "upload_base64_file")
fn.decorator_list = []
decoded = []
base64.b64decode = lambda c: decoded.append(c) or b""
class PermissionError(Exception): pass
def has_permission(dt, ptype, dn=None, throw=False): raise PermissionError(dt)
for name in ("PIL", "frappe", "frappe.handler"):
    m = types.ModuleType(name); sys.modules[name] = m
sys.modules["PIL"].Image = sys.modules["PIL"].ImageOps = None
sys.modules["frappe.handler"].ALLOWED_MIMETYPES = ("image/png",)
frappe = types.SimpleNamespace(has_permission=has_permission)
g = {"frappe": frappe, "_": lambda s: s}; exec(ast.unparse(fn), g)
try:
    g["upload_base64_file"]("A" * 1000, "x.png", "Employee", "EMP-2"); raise SystemExit("no PermissionError")
except PermissionError:
    pass
assert decoded == [], "decoded before the permission check"
PYT'
check "M27a stored-doc User Permission hook: write / submit / cancel / amend / delete need access to the STORED doc" 'python3 - "$H/hrms/hr/utils.py" <<"PYT"
import sys, types
src = open(sys.argv[1]).read()
code = src[src.index("# TREEO-SEC M27a"):]
# User Permission: emp@x is scoped to EMP-1; mgr@x to EMP-1 and EMP-2 (reports_to chain)
ALLOWED = {"emp@x": {"EMP-1"}, "mgr@x": {"EMP-1", "EMP-2"}}
STORED = {"EC-1": {"employee": "EMP-2"}, "EC-2": {"employee": "EMP-1"}}
seen = []
class Doc(dict):
    doctype = "Expense Claim"
def has_user_permission(doc, user=None, debug=False, ptype=None):
    seen.append((doc["name"], doc["employee"], user))
    return doc["employee"] in ALLOWED.get(user, set())
perms_mod = types.ModuleType("frappe.permissions"); perms_mod.has_user_permission = has_user_permission
frappe = types.ModuleType("frappe"); frappe.permissions = perms_mod
sys.modules["frappe"] = frappe; sys.modules["frappe.permissions"] = perms_mod
frappe.session = types.SimpleNamespace(user="emp@x")
frappe.db = types.SimpleNamespace(exists=lambda dt, n: dt == "Expense Claim" and n in STORED)
frappe.get_doc = lambda dt, n: Doc(name=n, **STORED[n])
g = {"frappe": frappe}; exec(code, g)
hp = g["treeo_stored_up_has_permission"]
# the attack: a colleague\x27s draft (stored EMP-2) PUT with employee set to oneself
for ptype in ("write", "submit", "cancel", "amend", "delete"):
    assert hp(Doc(name="EC-1", employee="EMP-1"), ptype, "emp@x") is False, ptype
    assert hp(Doc(name="EC-1", employee="EMP-1"), ptype) is False, ptype  # session user
    assert hp(Doc(name="EC-2", employee="EMP-1"), ptype, "emp@x") is None, ptype
    assert hp(Doc(name="EC-1", employee="EMP-2"), ptype, "mgr@x") is None, ptype
assert seen[0] == ("EC-1", "EMP-2", "emp@x"), seen  # checked the stored doc, not the new values
seen.clear()
for ptype in ("read", "create", "print", "email", "report", None):
    assert hp(Doc(name="EC-1", employee="EMP-1"), ptype, "emp@x") is None, ptype
assert hp(Doc(name="EC-1", employee="EMP-1"), "write", "Administrator") is None
assert hp(Doc(name="NEW-1", employee="EMP-1"), "write", "emp@x") is None  # not stored yet
assert hp(Doc(employee="EMP-1"), "write", "emp@x") is None
assert hp(Doc(name="EC-1", employee="EMP-1", __islocal=1), "write", "emp@x") is None
assert seen == [], seen
PYT'
check "M27b hooks: 12 self-service doctypes chain the stored-doc hook after any existing one" 'python3 - "$H/hrms/hooks.py" <<"PYT"
import sys
src = open(sys.argv[1]).read()
g = {}; exec(src, g)
hp = g["has_permission"]
M = "hrms.hr.utils.treeo_stored_up_has_permission"
DTS = ("Employee Grievance", "Expense Claim", "Employee Advance", "Leave Application", "Leave Encashment",
       "Attendance Request", "Compensatory Leave Request", "Shift Request", "Appraisal",
       "Employee Performance Feedback", "Employee Referral", "Training Feedback")
for dt in DTS:
    assert hp[dt] == [M], (dt, hp[dt])
assert sorted(d for d in hp if M in hp[d]) == sorted(DTS)
# chaining: an existing hook (string or list) is kept and M27a goes last, so frappe\x27s
# has_controller_permissions (reversed(), first non-None wins) asks M27a first
code = src[src.index("# TREEO-SEC M27b"):]
g = {"has_permission": {"Expense Claim": "x.ec", "Leave Application": ["y.la1", "y.la2"], "Salary Slip": "z.ss"}}
exec(code, g)
hp = g["has_permission"]
assert hp["Expense Claim"] == ["x.ec", M] and hp["Leave Application"] == ["y.la1", "y.la2", M], hp
assert hp["Salary Slip"] == "z.ss" and hp["Appraisal"] == [M]
def controller(methods, results):  # frappe.permissions.has_controller_permissions v15
    for m in reversed(methods):
        r = results[m]
        if r is not None:
            return bool(r)
    return True
assert controller(hp["Expense Claim"], {"x.ec": None, M: False}) is False
assert controller(hp["Expense Claim"], {"x.ec": False, M: None}) is False
assert controller(hp["Expense Claim"], {"x.ec": True, M: False}) is False  # M27a deny not overridden
assert controller(hp["Expense Claim"], {"x.ec": None, M: None}) is True
PYT'
if [ -n "${FRAPPE_DIR:-}" ] && [ -f "$FRAPPE_DIR/frappe/permissions.py" ]; then
  check "M27a frappe has_user_permission signature and hook combination match the assumptions" 'python3 - "$FRAPPE_DIR/frappe/permissions.py" "$FRAPPE_DIR/frappe/__init__.py" <<"PYT"
import sys
p, i = open(sys.argv[1]).read(), open(sys.argv[2]).read()
assert "def has_user_permission(doc, user=None, debug=False, ptype=None):" in p
assert "\tfor method in reversed(methods):\n\t\tcontroller_permission = frappe.call(method, doc=doc, ptype=ptype, user=user, debug=debug)" in p
assert "\t\tif controller_permission is not None:\n\t\t\treturn bool(controller_permission)" in p
assert "\tif not has_controller_permissions(doc, ptype, user=user, debug=debug):" in p
assert "\t\tif not isinstance(value, list):\n\t\t\tvalue = [value]\n\t\ttarget[key].extend(value)" in i
assert "\t\t\tif not key.startswith(\"_\"):\n\t\t\t\tappend_hook(hooks, key, value)" in i
PYT'
else
  echo "SKIP: FRAPPE_DIR not set (frappe v15 checkout) - has_permission hook semantics check"
fi
check "M27d-g, j read gate is the first statement of the whitelisted function" 'python3 - "$H" <<"PYT"
import ast, sys
want = {
    ("hrms/hr/doctype/vehicle_log/vehicle_log.py", "make_expense_claim"):
        "frappe.has_permission(\x27Vehicle Log\x27, \x27read\x27, docname, throw=True)",
    ("hrms/api/roster.py", "get_schedule_from_assignment"):
        "frappe.has_permission(\x27Shift Schedule Assignment\x27, \x27read\x27, shift_schedule_assignment, throw=True)",
    ("hrms/hr/doctype/training_result/training_result.py", "get_employees"):
        "frappe.has_permission(\x27Training Event\x27, \x27read\x27, training_event, throw=True)",
    ("hrms/hr/doctype/staffing_plan/staffing_plan.py", "get_designation_counts"):
        "frappe.has_permission(\x27Staffing Plan\x27, \x27read\x27, throw=True)",
    ("hrms/hr/doctype/expense_claim/expense_claim.py", "get_expense_claim"):
        "frappe.has_permission(\x27Employee Advance\x27, \x27read\x27, employee_advance_name, throw=True)",
}
for (rel, fn), first in want.items():
    tree = ast.parse(open(sys.argv[1] + "/" + rel).read())
    f = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == fn)
    assert ast.unparse(f.body[0]) == first, (rel, fn, ast.unparse(f.body[0]))
PYT'
check "M27h/i payroll frequency / employee currency assert own payroll first" 'python3 - "$H" <<"PYT"
import ast, sys
want = {
    ("hrms/payroll/doctype/salary_withholding/salary_withholding.py", "get_payroll_frequency"): "Salary Withholding",
    ("hrms/payroll/doctype/salary_structure_assignment/salary_structure_assignment.py", "get_employee_currency"):
        "Salary Structure Assignment",
}
for (rel, fn), dt in want.items():
    tree = ast.parse(open(sys.argv[1] + "/" + rel).read())
    f = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == fn)
    s = [ast.unparse(x) for x in f.body[:2]]
    assert s[0] == "from hrms.payroll.doctype.salary_slip.salary_slip import treeo_assert_own_payroll", (fn, s)
    assert s[1] == "treeo_assert_own_payroll(\x27%s\x27, employee)" % dt, (fn, s)
PYT'
check "every TREEO-SEC marker in the repo source has an injector patch (file, id, function)" 'python3 - "$REPO" "$SCRIPT" <<"PYT"
import ast, re, sys
from pathlib import Path
repo, script = Path(sys.argv[1]), Path(sys.argv[2]).read_text()
patches = ast.literal_eval(script[script.index("PATCHES = [") + len("PATCHES = "):script.index("\ncounts = ")])
markers = []
for top in ("hrms", "roster/src", "frontend/src"):
    for f in sorted((repo / top).rglob("*")):
        rel = str(f.relative_to(repo))
        if f.suffix not in (".py", ".js", ".html", ".vue") or "/tests/" in rel or "node_modules" in rel or f.name.startswith("test_"):
            continue
        lines = f.read_text(errors="ignore").split("\n")
        for i, l in enumerate(lines):
            m = re.search(r"TREEO-SEC ([A-Z]\d+[a-z]?)\b", l)
            if not m:
                continue
            ind, func = len(l) - len(l.lstrip()), None
            for k in range(i, -1, -1):
                d = re.match(r"(\s*)def (\w+)\(", lines[k])
                if d and len(d.group(1)) < ind:
                    func = d.group(2); break
            markers.append((rel, m.group(1), func))
def missing(ps):
    out = []
    for rel, mid, func in markers:
        pat = mid if mid[-1].islower() else mid + "[a-z]*"
        cands = [p for p in ps if p["file"] == rel and re.fullmatch(pat, p["id"])]
        if not any(func is None or "def %s(" % func in p.get("func", "") for p in cands):
            out.append((rel, mid, func))
    return out
assert len(markers) >= 8, markers
gap = missing(patches)
print("repo TREEO-SEC markers: %d, without injector patch: %s" % (len(markers), gap))
assert not gap
# the check would have caught F5 (get_advances had no injector patch before M5h)
assert missing([p for p in patches if p["id"] != "M5h"]) == [("hrms/hr/doctype/expense_claim/expense_claim.py", "M5", "get_advances")]
PYT'
state1="$(git -C apps/hrms diff | sha256sum)"

echo "== second run (idempotency)"
out2="$(bash "$SCRIPT" apps/hrms)"; rc2=$?
echo "$out2"
check "second run exits 0" '[ $rc2 -eq 0 ]'
check "second run applies nothing" 'echo "$out2" | grep -q "0 applied, 69 already present, 2 verified upstream, 0 skipped"'
check "second run leaves tree unchanged" '[ "$(git -C apps/hrms diff | sha256sum)" = "$state1" ]'

echo "== missing anchor"
git -C apps/hrms checkout -q -- .
sed -i 's/^def get_workflow(/def get_workflow_renamed(/' apps/hrms/hrms/api/__init__.py
out3="$(bash "$SCRIPT" apps/hrms)"; rc3=$?
echo "$out3" | grep -E "WARNING|Security patches"
check "missing anchor exits 0" '[ $rc3 -eq 0 ]'
check "missing anchor logs WARNING for M2a" 'echo "$out3" | grep -q "WARNING: security patch M2a"'
check "other patches still applied" 'echo "$out3" | grep -q "68 applied"'
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
check "F12 skipped M21b / M21c (and M27b, which extends the M21b dict) is critical: exit 3 with SECURITY ERROR" \
  '[ $rc7 -eq 3 ] && echo "$out7" | grep -q "SECURITY ERROR: critical security patch(es) M21b, M21c, M27b skipped"'

echo "== M27b needs the M27a hook (cross-file prerequisite, critical)"
git -C apps/hrms checkout -q -- .
printf "\n# TREEO-SEC M27a placeholder\n" >> apps/hrms/hrms/hr/utils.py
out11="$(bash "$SCRIPT" apps/hrms)"; rc11=$?
echo "$out11" | grep -E "M27|SECURITY|Security patches"
check "M27a already-marked file without the hook: M27b skipped, hooks.py has no M27b" \
  'echo "$out11" | grep -q "WARNING: security patch M27b" && ! grep -q "treeo_stored_up_has_permission" apps/hrms/hrms/hooks.py'
check "F12 skipped M27b is critical: exit 3 with SECURITY ERROR" \
  '[ $rc11 -eq 3 ] && echo "$out11" | grep -q "SECURITY ERROR: critical security patch(es) M27b skipped"'

echo "== F12 critical patch skipped (M10 anchor gone)"
git -C apps/hrms checkout -q -- .
sed -i 's/^def get_events(/def get_events_renamed(/' apps/hrms/hrms/api/roster.py
out8="$(bash "$SCRIPT" apps/hrms)"; rc8=$?
echo "$out8" | grep -E "WARNING|SECURITY|Security patches"
check "skipped M10 exits 3" '[ $rc8 -eq 3 ]'
check "skipped M10 prints SECURITY ERROR naming M10" 'echo "$out8" | grep -q "SECURITY ERROR: critical security patch(es) M10 skipped"'

echo "== F12 critical patch skipped (M24 anchor gone)"
git -C apps/hrms checkout -q -- .
sed -i 's/^\temail_success = \[\]$/\temail_success = list()/' apps/hrms/hrms/hr/doctype/exit_interview/exit_interview.py
out9="$(bash "$SCRIPT" apps/hrms)"; rc9=$?
echo "$out9" | grep -E "WARNING|SECURITY|Security patches"
check "skipped M24 exits 3 with SECURITY ERROR" '[ $rc9 -eq 3 ] && echo "$out9" | grep -q "SECURITY ERROR: critical security patch(es) M24 skipped"'

echo "== M5h upstream check removed"
git -C apps/hrms checkout -q -- .
python3 - apps/hrms/hrms/hr/doctype/expense_claim/expense_claim.py <<"PYT"
import sys
p = sys.argv[1]; s = open(p).read()
a = 'def get_advances(employee: str, advance_id: str | None = None, company: str | None = None):\n\tfrappe.has_permission("Employee", "read", employee, throw=True)\n'
assert s.count(a) == 1
open(p, "w").write(s.replace(a, a.split("\n")[0] + "\n"))
PYT
out10="$(bash "$SCRIPT" apps/hrms)"; rc10=$?
echo "$out10" | grep -E "WARNING|SECURITY|Security patches"
check "missing get_advances check: WARNING for M5h, not critical (exit 0)" '[ $rc10 -eq 0 ] && echo "$out10" | grep -q "WARNING: security patch M5h"'

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
