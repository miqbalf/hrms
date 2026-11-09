#!/bin/bash
# Inject TREEO security hardening (Strix review, 2026-11) into the freshly
# cloned upstream hrms app. Production does `rm -rf apps/hrms` + `bench get-app`
# from upstream frappe/hrms on every start, so fixes made in this repo's Python
# never reach production unless they are re-applied here. The same changes are
# made in the repo source (search for "TREEO-SEC").
#
# Usage: inject_security_patches.sh [APP_DIR]
#   APP_DIR  the hrms app checkout to patch (default: apps/hrms, i.e. run from
#            /home/frappe/frappe-bench).
#
# Guarantees:
#   - Idempotent: every patch carries a "TREEO-SEC <id>" marker and is skipped
#     when the marker is already present. Re-running changes nothing.
#   - Never breaks container start: a missing anchor or file, or a patch that
#     would not compile, logs a WARNING and that patch is skipped. The script
#     always exits 0.
#
# Patches:
#   M1  hrms.api.get_attendance_calendar_events: date range bounded to 366 days
#   M2  hrms.api.get_workflow / get_company_cost_center_and_expense_account:
#       read permission on the doctype / Company
#   M3  team_updates.get_data: role gate (Employee, System Manager) restored
#   M4  leave_ledger_entry.expire_allocation: upstream v15 already checks write
#       permission; we only verify that and warn if it ever disappears
#   M5  payroll / payment helpers: read permission on the referenced document
#       or employee before amounts are returned
#   G1  hrms.utils.get_country (guest): validate request_ip, pass key/fields as
#       request params, 5 s timeout, LRU-bounded per-IP cache (1024 entries).
#       Same code as hrms/utils/__init__.py in this repo (commit da19ae060).

APP_DIR="${1:-apps/hrms}"

if [ ! -d "$APP_DIR/hrms" ]; then
  echo "WARNING: $APP_DIR/hrms not found; skipping security patches."
  exit 0
fi

python3 - "$APP_DIR" <<'PY' || echo "WARNING: security patch injector crashed; continuing without it."
import sys
from pathlib import Path

app = Path(sys.argv[1])

# Each patch: id, file, mode, and mode-specific fields.
#   insert: put `lines` after the `def` line starting with `func`, or, when
#           `after` is set, after that exact line inside the function body.
#   replace: swap the exact line `old` for `new`.
#   verify: only check that `expect` is present.
#   block: swap the exact run of lines `old` (must occur once) for `new`.
# `needs`: strings that must exist in the file (imports the patch relies on).
PATCHES = [
	{
		"id": "M1",
		"file": "hrms/api/__init__.py",
		"mode": "insert",
		"func": "def get_attendance_calendar_events(",
		"needs": ["from frappe import _", "date_diff"],
		"lines": [
			"\t# TREEO-SEC M1: bound the range so one request cannot loop over millions of days",
			"\tif not 0 <= date_diff(to_date, from_date) <= 366:",
			'\t\tfrappe.throw(_("Date range must be between 0 and 366 days."), frappe.ValidationError)',
		],
	},
	{
		"id": "M2a",
		"file": "hrms/api/__init__.py",
		"mode": "insert",
		"func": "def get_workflow(",
		"lines": ['\tfrappe.has_permission(doctype, "read", throw=True)  # TREEO-SEC M2a'],
	},
	{
		"id": "M2b",
		"file": "hrms/api/__init__.py",
		"mode": "insert",
		"func": "def get_company_cost_center_and_expense_account(",
		"lines": ['\tfrappe.has_permission("Company", "read", company, throw=True)  # TREEO-SEC M2b'],
	},
	{
		"id": "M3",
		"file": "hrms/hr/page/team_updates/team_updates.py",
		"mode": "replace",
		"old": "\t# frappe.only_for('Employee', 'System Manager')",
		"new": '\tfrappe.only_for(("Employee", "System Manager"))  # TREEO-SEC M3',
	},
	{
		"id": "M4",
		"file": "hrms/hr/doctype/leave_ledger_entry/leave_ledger_entry.py",
		"mode": "verify",
		"expect": 'frappe.has_permission("Leave Allocation", "write", allocation.name, throw=True)',
	},
	{
		"id": "M5a",
		"file": "hrms/overrides/employee_payment_entry.py",
		"mode": "insert",
		"func": "def get_payment_entry_for_employee(",
		"after": "\tdoc = frappe.get_doc(dt, dn)",
		"lines": ['\tdoc.check_permission("read")  # TREEO-SEC M5a'],
	},
	{
		"id": "M5b",
		"file": "hrms/overrides/employee_payment_entry.py",
		"mode": "insert",
		"func": "def get_reference_details_for_employee(",
		"after": "\tref_doc = frappe.get_doc(reference_doctype, reference_name)",
		"lines": ['\tref_doc.check_permission("read")  # TREEO-SEC M5b'],
	},
	{
		"id": "M5c",
		"file": "hrms/hr/doctype/expense_claim/expense_claim.py",
		"mode": "insert",
		"func": "def make_bank_entry(",
		"after": "\texpense_claim = frappe.get_doc(dt, dn)",
		"lines": ['\texpense_claim.check_permission("read")  # TREEO-SEC M5c'],
	},
	{
		"id": "M5d",
		"file": "hrms/hr/doctype/employee_advance/employee_advance.py",
		"mode": "insert",
		"func": "def make_bank_entry(",
		"after": "\tdoc = frappe.get_doc(dt, dn)",
		"lines": ['\tdoc.check_permission("read")  # TREEO-SEC M5d'],
	},
	{
		"id": "M5e",
		"file": "hrms/payroll/doctype/employee_benefit_application/employee_benefit_application.py",
		"mode": "insert",
		"func": "def get_max_benefits(",
		"lines": ['\tfrappe.has_permission("Employee", "read", employee, throw=True)  # TREEO-SEC M5e'],
	},
	{
		"id": "M5f",
		"file": "hrms/payroll/doctype/employee_benefit_application/employee_benefit_application.py",
		"mode": "insert",
		"func": "def get_max_benefits_remaining(",
		"lines": ['\tfrappe.has_permission("Employee", "read", employee, throw=True)  # TREEO-SEC M5f'],
	},
	{
		"id": "M5g",
		"file": "hrms/payroll/doctype/employee_benefit_application/employee_benefit_application.py",
		"mode": "insert",
		"func": "def get_earning_components_max_benefits(",
		"lines": ['\tfrappe.has_permission("Employee", "read", employee, throw=True)  # TREEO-SEC M5g'],
	},
	{
		"id": "G1",
		"file": "hrms/utils/__init__.py",
		"mode": "block",
		"old": [
			"country_info = {}",
			"",
			"",
			"@frappe.whitelist(allow_guest=True)",
			"def get_country(fields=None):",
			"\tglobal country_info",
			"\tip = frappe.local.request_ip",
			"",
			"\tif ip not in country_info:",
			'\t\tfields = ["countryCode", "country", "regionName", "city"]',
			"\t\tres = requests.get(",
			'\t\t\t"https://pro.ip-api.com/json/{ip}?key={key}&fields={fields}".format(',
			'\t\t\t\tip=ip, key=frappe.conf.get("ip-api-key"), fields=",".join(fields)',
			"\t\t\t)",
			"\t\t)",
			"",
			"\t\ttry:",
			"\t\t\tcountry_info[ip] = res.json()",
			"",
			"\t\texcept Exception:",
			"\t\t\tcountry_info[ip] = {}",
			"",
			"\treturn country_info[ip]",
		],
		"new": [
			"# TREEO-SEC G1: hardened guest geo-IP lookup (validated IP, params, timeout, bounded cache)",
			"import ipaddress  # noqa: E402",
			"from collections import OrderedDict  # noqa: E402",
			"",
			"country_info = OrderedDict()",
			"COUNTRY_INFO_CACHE_SIZE = 1024",
			"COUNTRY_LOOKUP_TIMEOUT = 5",
			"",
			"",
			"def _remember_country(ip, info):",
			"\tcountry_info[ip] = info",
			"\tcountry_info.move_to_end(ip)",
			"\twhile len(country_info) > COUNTRY_INFO_CACHE_SIZE:",
			"\t\tcountry_info.popitem(last=False)",
			"",
			"",
			"@frappe.whitelist(allow_guest=True)",
			"def get_country(fields=None):",
			"\ttry:",
			'\t\tip = str(ipaddress.ip_address((frappe.local.request_ip or "").strip()))',
			"\texcept ValueError:",
			"\t\treturn {}",
			"",
			"\tif ip in country_info:",
			"\t\tcountry_info.move_to_end(ip)",
			"\t\treturn country_info[ip]",
			"",
			'\tfields = ["countryCode", "country", "regionName", "city"]',
			"\ttry:",
			"\t\tres = requests.get(",
			'\t\t\tf"https://pro.ip-api.com/json/{ip}",',
			'\t\t\tparams={"key": frappe.conf.get("ip-api-key"), "fields": ",".join(fields)},',
			"\t\t\ttimeout=COUNTRY_LOOKUP_TIMEOUT,",
			"\t\t)",
			"\t\tinfo = res.json()",
			"\t\tif not isinstance(info, dict):",
			"\t\t\tinfo = {}",
			"\texcept Exception:",
			"\t\tinfo = {}",
			"",
			"\t_remember_country(ip, info)",
			"\treturn info",
		],
	},
]

counts = {"applied": 0, "already": 0, "ok": 0, "skipped": 0}


def warn(pid, msg):
	counts["skipped"] += 1
	print(f"WARNING: security patch {pid}: {msg}; skipped.")


def apply_insert(p, lines):
	starts = [i for i, l in enumerate(lines) if l.startswith(p["func"])]
	if len(starts) != 1:
		return f"found {len(starts)} definitions of '{p['func']}' (expected 1)"
	i = starts[0]
	if "after" not in p:
		if not lines[i].rstrip().endswith(":"):
			return "def line does not end with ':' (multi-line signature)"
		at = i + 1
	else:
		at = None
		for j in range(i + 1, len(lines)):
			l = lines[j]
			if l and not l[0].isspace():  # next top-level statement: end of function
				break
			if l.rstrip() == p["after"]:
				at = j + 1
				break
		if at is None:
			return f"anchor line not found in {p['func']}...)"
	lines[at:at] = p["lines"]
	return None


def apply_block(p, lines):
	old, n = p["old"], len(p["old"])
	hits = [i for i in range(len(lines) - n + 1) if [l.rstrip() for l in lines[i : i + n]] == old]
	if len(hits) != 1:
		return f"found {len(hits)} copies of the block to replace (expected 1; upstream changed?)"
	lines[hits[0] : hits[0] + n] = p["new"]
	return None


def apply_replace(p, lines):
	hits = [i for i, l in enumerate(lines) if l.rstrip() == p["old"]]
	if len(hits) != 1:
		return f"found {len(hits)} copies of the line to replace (expected 1)"
	lines[hits[0]] = p["new"]
	return None


for p in PATCHES:
	pid = p["id"]
	path = app / p["file"]
	if not path.is_file():
		warn(pid, f"{p['file']} not found")
		continue
	text = path.read_text()

	if p["mode"] == "verify":
		if p["expect"] in text:
			counts["ok"] += 1
			print(f"security patch {pid}: upstream already has the check.")
		else:
			warn(pid, f"expected upstream check missing from {p['file']} - review manually")
		continue

	if f"TREEO-SEC {pid}" in text:
		counts["already"] += 1
		print(f"security patch {pid}: already applied.")
		continue

	missing = [n for n in p.get("needs", []) if n not in text]
	if missing:
		warn(pid, f"{p['file']} lacks {missing}")
		continue

	lines = text.split("\n")
	apply = {"insert": apply_insert, "replace": apply_replace, "block": apply_block}[p["mode"]]
	err = apply(p, lines)
	if err:
		warn(pid, f"{p['file']}: {err}")
		continue

	new_text = "\n".join(lines)
	try:
		compile(new_text, str(path), "exec")
	except SyntaxError as e:
		warn(pid, f"patched {p['file']} would not compile ({e})")
		continue

	tmp = path.with_suffix(path.suffix + ".treeo-tmp")
	tmp.write_text(new_text)
	tmp.replace(path)
	counts["applied"] += 1
	print(f"security patch {pid}: applied to {p['file']}.")

print(
	"Security patches: {applied} applied, {already} already present, "
	"{ok} verified upstream, {skipped} skipped.".format(**counts)
)
PY

exit 0
