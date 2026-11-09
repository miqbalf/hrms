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
#   - A single missed patch never breaks container start: a missing anchor or
#     file, or a patch that would not compile, logs a WARNING and that patch
#     is skipped (owner decision 2026-11-09: warn per patch).
#   - Loud when something is missed: any skipped patch ends with a line
#     "SECURITY WARNING: N patches skipped" - grep the start log for it.
#   - Fails closed when nothing is protected: a missing app dir, an injector
#     crash, or a run where no patch was applied or already present prints
#     "SECURITY ERROR: ..." and exits 1 (docker-compose.coolify.yml then
#     refuses to start). Otherwise it exits 0.
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
#       Same code as hrms/utils/__init__.py in this repo (commit da19ae060);
#       this patch is the only way it reaches production.
#   M6  full_and_final_statement.get_account_and_amount: read permission on the
#       referenced document
#   M7  attendance.get_unmarked_days: date range bounded to 366 days (as M1)
#   M8  interview.get_feedback / get_skill_wise_average_rating: read permission
#       on the Interview; interview.get_interviewers: read permission on the
#       Interview Round (its only argument); job_applicant.get_interview_details:
#       read permission on the Job Applicant
#   M9  appraisal.get_feedback_history: read permission on the Appraisal
#   M10 hrms.api.roster.get_events: role gate (HR Manager, HR User, System
#       Manager) and allow-listed filter keys. frappe v15 frappe.qb.get_query
#       does no permission or user-permission checks, so without this any user
#       could read every employee's leaves and shifts.
#   M11 employee_checkin.add_log_based_on_employee_field: employee_fieldname
#       limited to attendance_device_id / name (no lookup by arbitrary field)
#   M12 EmployeeCheckin.validate: without HR Manager / HR User / System Manager,
#       a checkin must be for the caller's own employee and (on insert or time
#       change) within 5 minutes of server time. The Employee role has create.
#   M13 hr.utils.get_employee_field_property: only the fields the Employee
#       Promotion / Transfer dialog offers, and only at a readable permlevel
#   M14 read gates on whitelisted readers: a organizational_chart.get_children
#       (page roles), b leave_application.get_leave_approver (Employee read on
#       direct API calls), c staffing_plan.get_active_staffing_plan_details
#       (Staffing Plan read), d payroll_entry.get_payroll_entries_for_jv
#       (Payroll Entry read or Journal Entry create), e appraisal_cycle.
#       get_appraisal_cycle_summary (cycle read), f employee_boarding_controller.
#       get_onboarding_details (template allow-list + read/create), g hrms.api.
#       get_doctype_fields (doctype read for non-child doctypes)
#   M15 salary_slip.enqueue_email_salary_slips: email permission on every slip
#   M16 hierarchy_chart.get_all_nodes: method limited to the org chart getter

APP_DIR="${1:-apps/hrms}"

if [ ! -d "$APP_DIR/hrms" ]; then
  echo "SECURITY ERROR: $APP_DIR/hrms not found; security patches NOT applied."
  exit 1
fi

python3 - "$APP_DIR" <<'PY'
import re
import shutil
import sys
from pathlib import Path

app = Path(sys.argv[1])

# Each patch: id, file, mode, and mode-specific fields.
#   insert: put `lines` after the `def` line starting with `func`, or, when
#           `after` is set, after that exact line inside the function body,
#           or, when `before` is set, before that exact line inside the
#           function body (for multi-line signatures).
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
		"id": "M6",
		"file": "hrms/hr/doctype/full_and_final_statement/full_and_final_statement.py",
		"mode": "insert",
		"func": "def get_account_and_amount(",
		"after": "\t\treturn None",
		"lines": [
			"",
			'\tfrappe.has_permission(ref_doctype, "read", ref_document, throw=True)  # TREEO-SEC M6',
		],
	},
	{
		"id": "M7",
		"file": "hrms/hr/doctype/attendance/attendance.py",
		"mode": "insert",
		"func": "def get_unmarked_days(",
		"after": '\tfrappe.has_permission("Employee", "read", employee, throw=True)',
		"needs": ["from frappe import _"],
		"lines": [
			"\t# TREEO-SEC M7: bound the range so one request cannot loop over millions of days",
			"\tif not 0 <= frappe.utils.date_diff(to_date, from_date) <= 366:",
			'\t\tfrappe.throw(_("Date range must be between 0 and 366 days."), frappe.ValidationError)',
		],
	},
	{
		"id": "M8a",
		"file": "hrms/hr/doctype/interview/interview.py",
		"mode": "insert",
		"func": "def get_feedback(",
		"lines": ['\tfrappe.has_permission("Interview", "read", interview, throw=True)  # TREEO-SEC M8a'],
	},
	{
		"id": "M8b",
		"file": "hrms/hr/doctype/interview/interview.py",
		"mode": "insert",
		"func": "def get_skill_wise_average_rating(",
		"lines": ['\tfrappe.has_permission("Interview", "read", interview, throw=True)  # TREEO-SEC M8b'],
	},
	{
		"id": "M8c",
		"file": "hrms/hr/doctype/interview/interview.py",
		"mode": "insert",
		"func": "def get_interviewers(",
		"lines": [
			'\tfrappe.has_permission("Interview Round", "read", interview_round, throw=True)  # TREEO-SEC M8c'
		],
	},
	{
		"id": "M8d",
		"file": "hrms/hr/doctype/job_applicant/job_applicant.py",
		"mode": "insert",
		"func": "def get_interview_details(",
		"lines": ['\tfrappe.has_permission("Job Applicant", "read", job_applicant, throw=True)  # TREEO-SEC M8d'],
	},
	{
		"id": "M9",
		"file": "hrms/hr/doctype/appraisal/appraisal.py",
		"mode": "insert",
		"func": "def get_feedback_history(",
		"lines": ['\tfrappe.has_permission("Appraisal", "read", appraisal, throw=True)  # TREEO-SEC M9'],
	},
	{
		"id": "M10",
		"file": "hrms/api/roster.py",
		"mode": "insert",
		"func": "def get_events(",
		"before": "\tholidays = get_holidays(month_start, month_end, employee_filters)",
		"needs": ["from frappe import _"],
		"lines": [
			"\t# TREEO-SEC M10: frappe v15 qb.get_query applies no permissions, so gate by role",
			"\t# and only accept the filter keys the roster UI sends (they become raw WHERE columns)",
			'\tfrappe.only_for(("HR Manager", "HR User", "System Manager"))',
			"\temployee_filters = frappe.parse_json(employee_filters) or {}",
			"\tshift_filters = frappe.parse_json(shift_filters) or {}",
			"\tif not isinstance(employee_filters, dict) or not isinstance(shift_filters, dict):",
			'\t\tfrappe.throw(_("Filters must be objects."), frappe.ValidationError)',
			'\tallowed_employee = {"company", "department", "branch", "designation", "status"}',
			'\tallowed_shift = {"shift_type", "shift_location"}',
			"\tif set(employee_filters) - allowed_employee or set(shift_filters) - allowed_shift:",
			'\t\tfrappe.throw(_("Unsupported roster filter."), frappe.ValidationError)',
		],
	},
	{
		"id": "M11",
		"file": "hrms/hr/doctype/employee_checkin/employee_checkin.py",
		"mode": "insert",
		"func": "def add_log_based_on_employee_field(",
		"before": "\tif not employee_field_value or not timestamp:",
		"needs": ["from frappe import _"],
		"lines": [
			"\t# TREEO-SEC M11: only look employees up by the device id or the record name",
			'\tif employee_fieldname not in ("attendance_device_id", "name"):',
			'\t\tfrappe.throw(_("Unsupported employee_fieldname."), frappe.ValidationError)',
			"",
		],
	},
	{
		"id": "M12",
		"file": "hrms/hr/doctype/employee_checkin/employee_checkin.py",
		"mode": "insert",
		"func": "\tdef validate(self):",
		"needs": ["from frappe import _", "get_datetime"],
		"lines": [
			"\t\t# TREEO-SEC M12: the Employee role may create checkins, so without HR roles a user",
			"\t\t# may only log their own employee, at the current time (5 minute tolerance)",
			'\t\tif not {"HR Manager", "HR User", "System Manager"} & set(frappe.get_roles()):',
			'\t\t\town = frappe.get_all("Employee", filters={"user_id": frappe.session.user}, pluck="name")',
			"\t\t\tif not self.employee or self.employee not in own:",
			'\t\t\t\tfrappe.throw(_("You can only log check-ins for yourself."), frappe.PermissionError)',
			'\t\t\tif self.is_new() or self.has_value_changed("time"):',
			"\t\t\t\tdrift = (get_datetime(self.time) - frappe.utils.now_datetime()).total_seconds()",
			"\t\t\t\tif abs(drift) > 300:",
			"\t\t\t\t\tfrappe.throw(",
			'\t\t\t\t\t\t_("Check-in time must be within 5 minutes of the current time."),',
			"\t\t\t\t\t\tfrappe.ValidationError,",
			"\t\t\t\t\t)",
		],
	},
	{
		"id": "M13",
		"file": "hrms/hr/utils.py",
		"mode": "insert",
		"func": "def get_employee_field_property(",
		"after": '\tdoc = frappe.get_doc("Employee", employee, check_permission=True)',
		"needs": ["from frappe import _"],
		"lines": [
			"\t# TREEO-SEC M13: only fields the Employee Promotion / Transfer dialog offers",
			"\t# (employee_property_update.js), and only at a permlevel the caller can read",
			"\tif (",
			"\t\tfield.hidden",
			"\t\tor field.read_only",
			"\t\tor field.fieldtype",
			'\t\tin ("HTML", "Section Break", "Column Break", "Button", "Read Only", "Tab Break", "Table",',
			'\t\t\t"Table MultiSelect", "Password")',
			"\t\tor fieldname",
			'\t\tin ("naming_series", "employee", "first_name", "middle_name", "last_name", "marital_status",',
			'\t\t\t"ctc", "employee_name", "status", "image", "gender", "date_of_birth", "date_of_joining",',
			'\t\t\t"lft", "rgt", "old_parent")',
			'\t\tor not doc.has_permlevel_access_to(fieldname, df=field, permission_type="read")',
			"\t):",
			'\t\tfrappe.throw(_("Not permitted to read this employee field."), frappe.PermissionError)',
		],
	},
	{
		"id": "M14a",
		"file": "hrms/hr/page/organizational_chart/organizational_chart.py",
		"mode": "insert",
		"func": "def get_children(",
		"lines": [
			"\t# TREEO-SEC M14a: same roles as the Organizational Chart page (fields are already minimal)",
			'\tfrappe.only_for(("Employee", "HR User", "HR Manager", "System Manager"))',
		],
	},
	{
		"id": "M14b",
		"file": "hrms/hr/doctype/leave_application/leave_application.py",
		"mode": "insert",
		"func": "def get_leave_approver(",
		"lines": [
			"\t# TREEO-SEC M14b: a direct API call needs read access to the employee; internal callers",
			"\t# (validate_leave_access, get_leave_details) run their own checks and are not affected",
			'\trequest = getattr(frappe.local, "request", None)',
			"\trpc = f\"{request.path if request else ''} {(frappe.form_dict or {}).get('cmd') or ''}\"",
			'\tif "get_leave_approver" in rpc:',
			'\t\tfrappe.has_permission("Employee", "read", employee, throw=True)',
		],
	},
	{
		"id": "M14c",
		"file": "hrms/hr/doctype/staffing_plan/staffing_plan.py",
		"mode": "insert",
		"func": "def get_active_staffing_plan_details(",
		"lines": [
			"\t# TREEO-SEC M14c: returns vacancies and total_estimated_cost (HR User / HR Manager only)",
			'\tfrappe.has_permission("Staffing Plan", "read", throw=True)',
		],
	},
	{
		"id": "M14d",
		"file": "hrms/payroll/doctype/payroll_entry/payroll_entry.py",
		"mode": "insert",
		"func": "def get_payroll_entries_for_jv(",
		"lines": [
			"\t# TREEO-SEC M14d: Journal Entry link search; Payroll Entry readers or JE creators only",
			'\tif not (frappe.has_permission("Payroll Entry", "read") or frappe.has_permission("Journal Entry", "create")):',
			"\t\traise frappe.PermissionError",
		],
	},
	{
		"id": "M14e",
		"file": "hrms/hr/doctype/appraisal_cycle/appraisal_cycle.py",
		"mode": "insert",
		"func": "def get_appraisal_cycle_summary(",
		"lines": ['\tfrappe.has_permission("Appraisal Cycle", "read", cycle_name, throw=True)  # TREEO-SEC M14e'],
	},
	{
		"id": "M14f",
		"file": "hrms/controllers/employee_boarding_controller.py",
		"mode": "insert",
		"func": "def get_onboarding_details(",
		"needs": ["from frappe import _"],
		"lines": [
			"\t# TREEO-SEC M14f: only the two boarding templates, for users who can read the template",
			"\t# or create / edit the onboarding or separation it is copied into",
			'\ttarget = {"Employee Onboarding Template": "Employee Onboarding",',
			'\t\t"Employee Separation Template": "Employee Separation"}.get(parenttype)',
			"\tif not target:",
			'\t\tfrappe.throw(_("Unsupported parenttype."), frappe.ValidationError)',
			"\tif not (",
			'\t\tfrappe.has_permission(parenttype, "read", parent)',
			'\t\tor frappe.has_permission(target, "create")',
			'\t\tor frappe.has_permission(target, "write")',
			"\t):",
			"\t\traise frappe.PermissionError",
		],
	},
	{
		"id": "M14g",
		"file": "hrms/api/__init__.py",
		"mode": "insert",
		"func": "def get_doctype_fields(",
		"lines": [
			"\t# TREEO-SEC M14g: schema only for doctypes the caller can read (child tables hold no rows here)",
			"\tif not frappe.get_meta(doctype).istable:",
			'\t\tfrappe.has_permission(doctype, "read", throw=True)',
		],
	},
	{
		"id": "M15",
		"file": "hrms/payroll/doctype/salary_slip/salary_slip.py",
		"mode": "insert",
		"func": "def enqueue_email_salary_slips(",
		"before": '\tfrappe.enqueue("hrms.payroll.doctype.salary_slip.salary_slip.email_salary_slips", names=names)',
		"needs": ["from frappe import _"],
		"lines": [
			"\t# TREEO-SEC M15: the caller needs email permission on every slip (the Employee role has none)",
			"\tif not isinstance(names, list):",
			'\t\tfrappe.throw(_("names must be a list."), frappe.ValidationError)',
			"\tfor n in names:",
			'\t\tfrappe.has_permission("Salary Slip", "email", n, throw=True)',
			"",
		],
	},
	{
		"id": "M16",
		"file": "hrms/utils/hierarchy_chart.py",
		"mode": "insert",
		"func": "def get_all_nodes(",
		"before": "\tmethod = frappe.get_attr(method)",
		"needs": ["from frappe import _"],
		"lines": [
			"\t# TREEO-SEC M16: only the org chart getter (get_attr would import any dotted path)",
			'\tif method != "hrms.hr.page.organizational_chart.organizational_chart.get_children":',
			'\t\tfrappe.throw(_("Not Permitted"), frappe.PermissionError)',
		],
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
	if "after" not in p and "before" not in p:
		if not lines[i].rstrip().endswith(":"):
			return "def line does not end with ':' (multi-line signature)"
		at = i + 1
	else:
		anchor, offset = (p["after"], 1) if "after" in p else (p["before"], 0)
		at = None
		for j in range(i + 1, len(lines)):
			l = lines[j]
			# next top-level statement: end of function (a multi-line signature
			# closes with an unindented ") ...:" line, which is still the def)
			if l and not l[0].isspace() and not l.startswith(")"):
				break
			if l.rstrip() == anchor:
				at = j + offset
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

	# word boundary: the marker of M1 must not match "TREEO-SEC M10" / "M11"
	if re.search(rf"TREEO-SEC {re.escape(pid)}\b", text):
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
	shutil.copymode(path, tmp)  # keep the upstream file mode (some files are 0755)
	tmp.replace(path)
	counts["applied"] += 1
	print(f"security patch {pid}: applied to {p['file']}.")

print(
	"Security patches: {applied} applied, {already} already present, "
	"{ok} verified upstream, {skipped} skipped.".format(**counts)
)
if counts["skipped"]:
	print(f"SECURITY WARNING: {counts['skipped']} patches skipped - production is missing those fixes; review the WARNING lines above.")
if counts["applied"] + counts["already"] == 0:
	# nothing applied and nothing present: wrong tree or every anchor moved
	print("SECURITY ERROR: no security patch is applied or present - refusing to continue.")
	sys.exit(3)
PY
rc=$?
if [ $rc -ne 0 ]; then
  [ $rc -eq 3 ] || echo "SECURITY ERROR: security patch injector crashed (exit $rc); patches may NOT be applied."
  exit 1
fi

exit 0
