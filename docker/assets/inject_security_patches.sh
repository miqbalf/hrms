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
#     refuses to start).
#   - Fails closed on a critical skip (F12): when any of M10, M12, M15, M21a,
#     M21b, M21c, M24, M27a, M27b or M28 is skipped it prints "SECURITY ERROR:
#     critical security patch(es) ... skipped" and exits 3. Otherwise it exits 0.
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
#       a checkin must be for the caller's own employee (the Employee role has
#       create). Opt-in time window: site config treeo_checkin_max_skew_seconds
#       (unset/0 = off); when set, the time on insert or change must be within
#       that many seconds of server time or of now in the user's User.time_zone.
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
#   M17 goal.py: a..c Goal.validate / Goal.on_trash call treeo_goal_write_gate; only
#       HR roles, the goal's employee or their direct manager may save or delete a
#       goal (upstream only guarded update_progress / update_status; a REST save
#       rewrote the linked Appraisal score)
#   M18 feedback_history.html (Interview / Appraisal feedback): a feedback text,
#       b reviewer name, c designation escaped (frappe templates do not escape)
#   M19 roster MonthViewTable.vue: holiday description rendered as text, not v-html
#   M20 team updates: a get_data only returns replies of the caller's own Daily
#       Work Summary groups (HR roles see all) and sanitises the reply HTML;
#       b team_update_row.html escapes the sender name in the title attribute
#   M21 payroll scoping: a salary_slip.py helpers, b hooks.py has_permission +
#       permission_query_conditions for Salary Slip / Salary Structure Assignment:
#       full access only for Administrator, HR Manager, HR User (System Manager only
#       with its own doctype grant); everyone else sees only own-Employee records
#       (also covers hrms.api.download_salary_slip, which uses print permission)
#   M22 job board: a JobOpening.validate rejects a route with a scheme or //host,
#       b www/jobs/index.js navigates to "/" + route (path only), c JobOpening.validate
#       rejects quotes, <, >, backtick, whitespace and // in route / job_application_route
#       and quotes, <, > in job_title, d www/jobs/index.html and e, f the job page
#       (templates/generators/job_opening.html) escape them (|e) in id / title / href
#   M5h expense_claim.get_advances: v15.64.8 already checks Employee read (verify only;
#       the repo's TREEO-SEC M5 fix is for the develop signature)
#   M12b Employee Checkin has_permission + query conditions (c hooks): without HR Manager /
#       HR User / System Manager only own-Employee checkins (read, write, delete)
#   M21c the M21 rule also for Employee Promotion, Employee Incentive, Retention Bonus,
#       Salary Withholding, Employee Benefit Application / Claim, Employee Tax Exemption
#       Declaration / Proof Submission and Employee Other Income
#   M23 a salary_slip.treeo_assert_own_payroll; b..d employee_benefit_application.
#       get_max_benefits / get_max_benefits_remaining / get_earning_components_max_benefits
#       call it after the M5e-g Employee read check (own employee unless HR)
#   M24 exit_interview.send_exit_questionnaire: email permission on every interview
#   M25 a JobApplicant.validate, b EmployeeReferral.validate: resume_link http(s) only
#   M26 hrms.api.upload_base64_file: write permission checked before the base64 decode
#   M27 Strix triage 2026-11-09: a hr.utils.treeo_stored_up_has_permission, b hooks.py
#       registers it (after any existing hook) for Employee Grievance, Expense Claim,
#       Employee Advance, Leave Application, Leave Encashment, Attendance Request,
#       Compensatory Leave Request, Shift Request, Appraisal, Employee Performance Feedback,
#       Employee Referral and Training Feedback: write / submit / cancel / amend / delete
#       also need User Permission access to the STORED document (frappe checked only the
#       new values, so an employee could take over a colleague's draft); read gates on
#       d vehicle_log.make_expense_claim (Vehicle Log), e roster.get_schedule_from_assignment
#       (Shift Schedule Assignment), f training_result.get_employees (Training Event),
#       g staffing_plan.get_designation_counts (Staffing Plan, as M14c), j expense_claim.
#       get_expense_claim (Employee Advance); h salary_withholding.get_payroll_frequency and
#       i salary_structure_assignment.get_employee_currency call treeo_assert_own_payroll
#       (M23a). M27c (manager grievance visibility) is an open owner decision, not here.
#   M28 SalaryComponent.update_salary_structures (run_doc_method, which checks only read,
#       and Employee has read): Salary Component write, Salary Structure write, and field
#       limited to condition / formula, before any Salary Structure Detail row is rewritten
#   JS / HTML / Vue patches (M18-M20b, M22b, M22d-f) edit source before `bench build`;
#   the compose runs this injector before `bench build`, so they reach the bundle.

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
#   append: add `lines` at the end of the file (module-level helpers).
# `needs`: strings that must exist in the file (imports the patch relies on).
# `needs_file`: {other file: [strings]} that must exist there (e.g. a hook target).
# Python files must still compile after the patch; .html / .js / .vue files are
# patched before `bench build` and checked by the test greps instead.
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
		"func": "def get_data(",  # informational (marker coverage test)
		"old": "\t# frappe.only_for('Employee', 'System Manager')",
		"new": '\tfrappe.only_for(("Employee", "System Manager"))  # TREEO-SEC M3',
	},
	{
		"id": "M4",
		"file": "hrms/hr/doctype/leave_ledger_entry/leave_ledger_entry.py",
		"mode": "verify",
		"func": "def expire_allocation(",  # informational (marker coverage test)
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
		"needs": ["from frappe import _", "get_datetime", "cint"],
		"lines": [
			"\t\t# TREEO-SEC M12: the Employee role may create checkins, so without HR roles a user",
			"\t\t# may only log their own employee. Optional time window (site config",
			"\t\t# treeo_checkin_max_skew_seconds, off when unset/0): the PWA sends device-local",
			"\t\t# time, so accept server time or the user's own User.time_zone.",
			'\t\tif not {"HR Manager", "HR User", "System Manager"} & set(frappe.get_roles()):',
			'\t\t\town = frappe.get_all("Employee", filters={"user_id": frappe.session.user}, pluck="name")',
			"\t\t\tif not self.employee or self.employee not in own:",
			'\t\t\t\tfrappe.throw(_("You can only log check-ins for yourself."), frappe.PermissionError)',
			'\t\t\tmax_skew = cint(frappe.conf.get("treeo_checkin_max_skew_seconds"))',
			'\t\t\tif max_skew > 0 and (self.is_new() or self.has_value_changed("time")):',
			"\t\t\t\tlogged = get_datetime(self.time)",
			"\t\t\t\tnows = [frappe.utils.now_datetime()]",
			'\t\t\t\tuser_tz = frappe.db.get_value("User", frappe.session.user, "time_zone")',
			"\t\t\t\tif user_tz:",
			"\t\t\t\t\tnows.append(frappe.utils.get_datetime_in_timezone(user_tz).replace(tzinfo=None))",
			"\t\t\t\tif all(abs((logged - n).total_seconds()) > max_skew for n in nows):",
			"\t\t\t\t\tfrappe.throw(",
			'\t\t\t\t\t\t_("Check-in time must be within {0} seconds of the current time.").format(max_skew),',
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
		"id": "M17a",
		"file": "hrms/hr/doctype/goal/goal.py",
		"mode": "append",
		"needs": ["from frappe import _", "has_common", "HR_ROLES = "],
		"lines": [
			"# TREEO-SEC M17a: update_progress / update_status call validate_goal_access, but a plain",
			"# save or delete (REST /api/resource/Goal, desk form) did not, and the Employee role has",
			"# unscoped write on Goal. Saving a goal rewrites the linked Appraisal score. Only HR, the",
			"# goal's employee or that employee's direct manager may change it (old and new employee).",
			"def treeo_goal_write_gate(goal):",
			"\tif has_common(HR_ROLES, frappe.get_roles()):",
			"\t\treturn",
			"\tbefore = None if goal.is_new() else goal.get_doc_before_save()",
			"\temployees = {goal.employee, before.employee if before else goal.employee}",
			"\tfor employee in employees:",
			"\t\temp = frappe.db.get_value(\"Employee\", employee, [\"user_id\", \"reports_to\"], as_dict=True) if employee else None",
			"\t\tif emp and emp.user_id == frappe.session.user:",
			"\t\t\tcontinue",
			"\t\tif emp and emp.reports_to and frappe.db.get_value(\"Employee\", emp.reports_to, \"user_id\") == frappe.session.user:",
			"\t\t\tcontinue",
			"\t\tfrappe.throw(",
			"\t\t\t_(\"You are not permitted to change another employee's goal.\"),",
			"\t\t\tfrappe.PermissionError,",
			"\t\t\ttitle=_(\"Not Permitted\"),",
			"\t\t)",
		],
	},
	{
		"id": "M17b",
		"file": "hrms/hr/doctype/goal/goal.py",
		"mode": "insert",
		"func": "\tdef validate(self):",
		"needs": ["def treeo_goal_write_gate("],
		"lines": ["\t\ttreeo_goal_write_gate(self)  # TREEO-SEC M17b"],
	},
	{
		"id": "M17c",
		"file": "hrms/hr/doctype/goal/goal.py",
		"mode": "insert",
		"func": "\tdef on_trash(self):",
		"needs": ["def treeo_goal_write_gate("],
		"lines": ["\t\ttreeo_goal_write_gate(self)  # TREEO-SEC M17c"],
	},
	{
		"id": "M18a",
		"file": "hrms/public/js/templates/feedback_history.html",
		"mode": "replace",
		"old": "\t\t\t\t\t\t{{ feedback_history[i].feedback }}",
		"new": "\t\t\t\t\t\t{{ frappe.utils.escape_html(strip_html(feedback_history[i].feedback)) }}<!-- TREEO-SEC M18a -->",
	},
	{
		"id": "M18b",
		"file": "hrms/public/js/templates/feedback_history.html",
		"mode": "replace",
		"old": "\t\t\t\t\t\t\t\t\t{{ strip_html(feedback_history[i].reviewer_name || feedback_history[i].user) }}",
		"new": "\t\t\t\t\t\t\t\t\t{{ frappe.utils.escape_html(strip_html(feedback_history[i].reviewer_name || feedback_history[i].user)) }}<!-- TREEO-SEC M18b -->",
	},
	{
		"id": "M18c",
		"file": "hrms/public/js/templates/feedback_history.html",
		"mode": "replace",
		"old": "\t\t\t\t\t\t\t\t\t\t{{ strip_html(feedback_history[i].reviewer_designation) }}",
		"new": "\t\t\t\t\t\t\t\t\t\t{{ frappe.utils.escape_html(strip_html(feedback_history[i].reviewer_designation)) }}<!-- TREEO-SEC M18c -->",
	},
	{
		"id": "M19",
		"file": "roster/src/components/MonthViewTable.vue",
		"mode": "block",
		"old": [
			"\t\t\t\t\t\t\t<div",
			"\t\t\t\t\t\t\t\tv-html=\"",
			"\t\t\t\t\t\t\t\t\tevents.data[employee.name][day.date].weekly_off",
			"\t\t\t\t\t\t\t\t\t\t? '<strong>WO</strong>'",
			"\t\t\t\t\t\t\t\t\t\t: events.data[employee.name][day.date].description",
			"\t\t\t\t\t\t\t\t\"",
			"\t\t\t\t\t\t\t></div>",
		],
		"new": [
			"\t\t\t\t\t\t\t<!-- TREEO-SEC M19: holiday description as text, not raw HTML -->",
			"\t\t\t\t\t\t\t<div v-if=\"events.data[employee.name][day.date].weekly_off\"><strong>WO</strong></div>",
			"\t\t\t\t\t\t\t<div",
			"\t\t\t\t\t\t\t\tv-else",
			"\t\t\t\t\t\t\t\tv-text=\"String(events.data[employee.name][day.date].description || '').replace(/<[^>]*>/g, ' ').trim()\"",
			"\t\t\t\t\t\t\t></div>",
		],
	},
	{
		"id": "M20a",
		"file": "hrms/hr/page/team_updates/team_updates.py",
		"mode": "block",
		"old": [
			"\tdata = frappe.get_all(",
			"\t\t\"Communication\",",
			"\t\tfields=(\"content\", \"text_content\", \"sender\", \"creation\"),",
			"\t\tfilters=dict(reference_doctype=\"Daily Work Summary\"),",
			"\t\torder_by=\"creation desc\",",
			"\t\tlimit=40,",
			"\t\tstart=start,",
			"\t)",
			"",
			"\tfor d in data:",
			"\t\td.sender_name = frappe.db.get_value(\"Employee\", {\"user_id\": d.sender}, \"employee_name\") or d.sender",
			"\t\tif d.text_content:",
			"\t\t\td.content = frappe.utils.md_to_html(EmailReplyParser.parse_reply(d.text_content))",
			"",
			"\treturn data",
		],
		"new": [
			"\t# TREEO-SEC M20a: without an HR role, only replies of the caller's own Daily Work Summary",
			"\t# groups; and the reply HTML is sanitised (md_to_html passes raw HTML through, and the",
			"\t# page inserts it unescaped)",
			"\tfrom frappe.utils.html_utils import sanitize_html",
			"",
			"\tfilters = dict(reference_doctype=\"Daily Work Summary\")",
			"\tif not {\"HR Manager\", \"HR User\", \"System Manager\"} & set(frappe.get_roles()):",
			"\t\tgroups = frappe.get_all(",
			"\t\t\t\"Daily Work Summary Group User\",",
			"\t\t\tfilters={\"user\": frappe.session.user, \"parenttype\": \"Daily Work Summary Group\"},",
			"\t\t\tpluck=\"parent\",",
			"\t\t)",
			"\t\tsummaries = (",
			"\t\t\tfrappe.get_all(\"Daily Work Summary\", filters={\"daily_work_summary_group\": [\"in\", groups]}, pluck=\"name\")",
			"\t\t\tif groups",
			"\t\t\telse []",
			"\t\t)",
			"\t\tif not summaries:",
			"\t\t\treturn []",
			"\t\tfilters[\"reference_name\"] = [\"in\", summaries]",
			"\tdata = frappe.get_all(",
			"\t\t\"Communication\",",
			"\t\tfields=(\"content\", \"text_content\", \"sender\", \"creation\"),",
			"\t\tfilters=filters,",
			"\t\torder_by=\"creation desc\",",
			"\t\tlimit=40,",
			"\t\tstart=start,",
			"\t)",
			"",
			"\tfor d in data:",
			"\t\td.sender_name = frappe.db.get_value(\"Employee\", {\"user_id\": d.sender}, \"employee_name\") or d.sender",
			"\t\tif d.text_content:",
			"\t\t\td.content = frappe.utils.md_to_html(EmailReplyParser.parse_reply(d.text_content))",
			"\t\td.content = sanitize_html(d.content or \"\", always_sanitize=True)",
			"",
			"\treturn data",
		],
	},
	{
		"id": "M20b",
		"file": "hrms/hr/page/team_updates/team_update_row.html",
		"mode": "replace",
		"old": "\t\ttitle=\"{%= by %} / {%= frappe.datetime.str_to_user(creation) %}\">",
		"new": "\t\ttitle=\"{%= frappe.utils.escape_html(by) %} / {%= frappe.datetime.str_to_user(creation) %}\"><!-- TREEO-SEC M20b -->",
	},
	{
		"id": "M21a",
		"file": "hrms/payroll/doctype/salary_slip/salary_slip.py",
		"mode": "append",
		"lines": [
			"# TREEO-SEC M21a: Employee / Employee Self Service read every Salary Slip and Salary",
			"# Structure Assignment (no if_owner, also in prod Custom DocPerm); only data-dependent User",
			"# Permissions narrowed it. Explicit rule: full access for Administrator, HR Manager and",
			"# HR User (System Manager only when that role itself has a read grant on the doctype);",
			"# everyone else only records of their own Employee (Employee.user_id == user).",
			"TREEO_PAYROLL_FULL_ROLES = {\"HR Manager\", \"HR User\"}",
			"",
			"",
			"def treeo_only_own_payroll(doctype, user):",
			"\tfrom frappe.permissions import get_valid_perms",
			"",
			"\tif user == \"Administrator\":",
			"\t\treturn False",
			"\troles = set(frappe.get_roles(user))",
			"\tif roles & TREEO_PAYROLL_FULL_ROLES:",
			"\t\treturn False",
			"\tif \"System Manager\" in roles and any(",
			"\t\tp.get(\"read\") and p.get(\"role\") == \"System Manager\" for p in get_valid_perms(doctype, user)",
			"\t):",
			"\t\treturn False",
			"\treturn True",
			"",
			"",
			"def treeo_own_payroll_has_permission(doc, ptype=None, user=None, debug=False):",
			"\tuser = user or frappe.session.user",
			"\tif not treeo_only_own_payroll(doc.doctype, user):",
			"\t\treturn None",
			"\t# the stored employee too, so a write cannot move another employee's record to oneself",
			"\temployees = {doc.get(\"employee\")}",
			"\tstored = frappe.db.get_value(doc.doctype, doc.get(\"name\"), \"employee\") if doc.get(\"name\") else None",
			"\tif stored:",
			"\t\temployees.add(stored)",
			"\tif all(e and frappe.db.get_value(\"Employee\", e, \"user_id\") == user for e in employees):",
			"\t\treturn None",
			"\treturn False",
			"",
			"",
			"def treeo_own_payroll_query_conditions(user=None, doctype=None):",
			"\tuser = user or frappe.session.user",
			"\tdoctype = doctype or \"Salary Slip\"",
			"\tif not treeo_only_own_payroll(doctype, user):",
			"\t\treturn \"\"",
			"\treturn \"`tab{0}`.`employee` in (select `name` from `tabEmployee` where `user_id` = {1})\".format(",
			"\t\tdoctype, frappe.db.escape(user)",
			"\t)",
		],
	},
	{
		"id": "M21b",
		"file": "hrms/hooks.py",
		"mode": "block",
		"needs_file": {
			"hrms/payroll/doctype/salary_slip/salary_slip.py": [
				"def treeo_own_payroll_has_permission(",
				"def treeo_own_payroll_query_conditions(",
			]
		},
		"old": [
			"# has_permission = {",
			"# \t\"Event\": \"frappe.desk.doctype.event.event.has_permission\",",
			"# }",
		],
		"new": [
			"# has_permission = {",
			"# \t\"Event\": \"frappe.desk.doctype.event.event.has_permission\",",
			"# }",
			"",
			"# TREEO-SEC M21b: Employee-only readers see only their own payroll records",
			"_treeo_payroll = \"hrms.payroll.doctype.salary_slip.salary_slip.treeo_own_payroll\"",
			"has_permission = {",
			"\t\"Salary Slip\": _treeo_payroll + \"_has_permission\",",
			"\t\"Salary Structure Assignment\": _treeo_payroll + \"_has_permission\",",
			"}",
			"permission_query_conditions = {",
			"\t\"Salary Slip\": _treeo_payroll + \"_query_conditions\",",
			"\t\"Salary Structure Assignment\": _treeo_payroll + \"_query_conditions\",",
			"}",
		],
	},
	{
		"id": "M22a",
		"file": "hrms/hr/doctype/job_opening/job_opening.py",
		"mode": "insert",
		"func": "\tdef validate(self):",
		"before": "\t\tself.update_closing_date()",
		"needs": ["from frappe import _"],
		"lines": [
			"\t\t# TREEO-SEC M22a: /jobs navigates to the route on click; only a path on this site",
			"\t\t# (no javascript: or other scheme in the first segment, no //host)",
			"\t\troute = self.route.strip().replace(\"\\\\\", \"/\")",
			"\t\tif \":\" in route.split(\"/\")[0] or route.startswith(\"//\"):",
			"\t\t\tfrappe.throw(_(\"Route must be a path on this site.\"), frappe.ValidationError)",
		],
	},
	{
		"id": "M22b",
		"file": "hrms/www/jobs/index.js",
		"mode": "replace",
		"old": "\t\twindow.location.href = this.id;",
		"new": "\t\twindow.location.href = \"/\" + String(this.id).replace(/^[\\s/\\\\]+/, \"\"); // TREEO-SEC M22b: path only",
	},
	{
		# repo source has TREEO-SEC M5 in get_advances (3b7078cc5, develop signature taking an
		# expense_claim doc); v15.64.8 takes `employee` and already checks Employee read on it
		"id": "M5h",
		"file": "hrms/hr/doctype/expense_claim/expense_claim.py",
		"mode": "verify",
		"func": "def get_advances(",
		"expect": 'def get_advances(employee: str, advance_id: str | None = None, company: str | None = None):\n\tfrappe.has_permission("Employee", "read", employee, throw=True)',
	},
	{
		"id": "M12b",
		"file": "hrms/hr/doctype/employee_checkin/employee_checkin.py",
		"mode": "append",
		"lines": [
			"# TREEO-SEC M12b: the Employee role has read / write / delete on every Employee Checkin",
			"# (GPS coordinates included) and M12 only guards validate (not delete, read, or a save with",
			"# ignore_validate such as bulk_fetch_shift). Without HR Manager / HR User / System Manager",
			"# a user may only use checkins of their own employee, before and after the change. The",
			"# PWA / mobile check-in runs as the employee, so own checkins keep working.",
			"TREEO_CHECKIN_FULL_ROLES = {\"HR Manager\", \"HR User\", \"System Manager\"}",
			"",
			"",
			"def treeo_checkin_full_access(user):",
			"\treturn user == \"Administrator\" or bool(TREEO_CHECKIN_FULL_ROLES & set(frappe.get_roles(user)))",
			"",
			"",
			"def treeo_checkin_has_permission(doc, ptype=None, user=None, debug=False):",
			"\tuser = user or frappe.session.user",
			"\tif treeo_checkin_full_access(user):",
			"\t\treturn None",
			"\temployees = {doc.get(\"employee\")}",
			"\tstored = frappe.db.get_value(\"Employee Checkin\", doc.get(\"name\"), \"employee\") if doc.get(\"name\") else None",
			"\tif stored:",
			"\t\temployees.add(stored)",
			"\tif all(e and frappe.db.get_value(\"Employee\", e, \"user_id\") == user for e in employees):",
			"\t\treturn None",
			"\treturn False",
			"",
			"",
			"def treeo_checkin_query_conditions(user=None, doctype=None):",
			"\tuser = user or frappe.session.user",
			"\tif treeo_checkin_full_access(user):",
			"\t\treturn \"\"",
			"\treturn \"`tabEmployee Checkin`.`employee` in (select `name` from `tabEmployee` where `user_id` = {0})\".format(",
			"\t\tfrappe.db.escape(user)",
			"\t)",
		],
	},
	{
		"id": "M21c",
		"file": "hrms/hooks.py",
		"mode": "block",
		"needs": ["TREEO-SEC M21b"],
		"old": [
			"permission_query_conditions = {",
			"\t\"Salary Slip\": _treeo_payroll + \"_query_conditions\",",
			"\t\"Salary Structure Assignment\": _treeo_payroll + \"_query_conditions\",",
			"}",
		],
		"new": [
			"permission_query_conditions = {",
			"\t\"Salary Slip\": _treeo_payroll + \"_query_conditions\",",
			"\t\"Salary Structure Assignment\": _treeo_payroll + \"_query_conditions\",",
			"}",
			"# TREEO-SEC M21c: the sibling payroll doctypes (Employee has unscoped read) follow the M21 rule",
			"for _treeo_dt in (",
			"\t\"Employee Promotion\",",
			"\t\"Employee Incentive\",",
			"\t\"Retention Bonus\",",
			"\t\"Salary Withholding\",",
			"\t\"Employee Benefit Application\",",
			"\t\"Employee Benefit Claim\",",
			"\t\"Employee Tax Exemption Declaration\",",
			"\t\"Employee Tax Exemption Proof Submission\",",
			"\t\"Employee Other Income\",",
			"):",
			"\thas_permission[_treeo_dt] = _treeo_payroll + \"_has_permission\"",
			"\tpermission_query_conditions[_treeo_dt] = _treeo_payroll + \"_query_conditions\"",
		],
	},
	{
		"id": "M12c",
		"file": "hrms/hooks.py",
		"mode": "block",
		"needs": ["TREEO-SEC M21b"],
		"needs_file": {
			"hrms/hr/doctype/employee_checkin/employee_checkin.py": [
				"def treeo_checkin_has_permission(",
				"def treeo_checkin_query_conditions(",
			]
		},
		"old": [
			"permission_query_conditions = {",
			"\t\"Salary Slip\": _treeo_payroll + \"_query_conditions\",",
			"\t\"Salary Structure Assignment\": _treeo_payroll + \"_query_conditions\",",
			"}",
		],
		"new": [
			"permission_query_conditions = {",
			"\t\"Salary Slip\": _treeo_payroll + \"_query_conditions\",",
			"\t\"Salary Structure Assignment\": _treeo_payroll + \"_query_conditions\",",
			"}",
			"# TREEO-SEC M12c: Employee Checkin, own records only without an HR role (M12b)",
			"has_permission[\"Employee Checkin\"] = \"hrms.hr.doctype.employee_checkin.employee_checkin.treeo_checkin_has_permission\"",
			"permission_query_conditions[\"Employee Checkin\"] = (",
			"\t\"hrms.hr.doctype.employee_checkin.employee_checkin.treeo_checkin_query_conditions\"",
			")",
		],
	},
	{
		"id": "M22c",
		"file": "hrms/hr/doctype/job_opening/job_opening.py",
		"mode": "insert",
		"func": "\tdef validate(self):",
		"before": "\t\tself.update_closing_date()",
		"needs": ["from frappe import _"],
		"lines": [
			"\t\t# TREEO-SEC M22c: /jobs and the job page put route / job_application_route in id and",
			"\t\t# href attributes and job_title in title attributes: no quote, tag, backtick, space or //",
			"\t\tfor value in (self.route, self.job_application_route):",
			"\t\t\tif value and (any(c in value for c in \"\\\"'<>`\") or any(c.isspace() for c in value) or \"//\" in value):",
			"\t\t\t\tfrappe.throw(_(\"Route must not contain quotes, <, >, backticks, spaces or //.\"), frappe.ValidationError)",
			"\t\tif self.job_title and any(c in self.job_title for c in \"\\\"<>\"):",
			"\t\t\tfrappe.throw(_(\"Job Title must not contain quotes, < or >.\"), frappe.ValidationError)",
		],
	},
	{
		"id": "M22d",
		"file": "hrms/www/jobs/index.html",
		"mode": "block",
		"old": [
			"\t\t\t\t\tid=\"{{ jo.route }}\"",
			"\t\t\t\t\tname=\"card\"",
			"\t\t\t\t\tclass=\"card border h-100 flex flex-col\"",
			"\t\t\t\t\trole=\"button\"",
			"\t\t\t\t>",
			"\t\t\t\t\t<div class=\"p-6\">",
			"\t\t\t\t\t\t<div class=\"flex mb-5\">",
			"\t\t\t\t\t\t\t<div class=\"col-12 {{ 'col-lg-9' if jo.employment_type }} px-0\">",
			"\t\t\t\t\t\t\t\t<h4",
			"\t\t\t\t\t\t\t\t\tclass=\"mt-0 mb-1 jobs-page text-truncate\"",
			"\t\t\t\t\t\t\t\t\ttitle=\"{{ jo.job_title }}\"",
			"\t\t\t\t\t\t\t\t>",
			"\t\t\t\t\t\t\t\t\t{{ jo.job_title }}",
		],
		"new": [
			"\t\t\t\t\tid=\"{{ jo.route|e }}\"{# TREEO-SEC M22d: route / job_title escaped #}",
			"\t\t\t\t\tname=\"card\"",
			"\t\t\t\t\tclass=\"card border h-100 flex flex-col\"",
			"\t\t\t\t\trole=\"button\"",
			"\t\t\t\t>",
			"\t\t\t\t\t<div class=\"p-6\">",
			"\t\t\t\t\t\t<div class=\"flex mb-5\">",
			"\t\t\t\t\t\t\t<div class=\"col-12 {{ 'col-lg-9' if jo.employment_type }} px-0\">",
			"\t\t\t\t\t\t\t\t<h4",
			"\t\t\t\t\t\t\t\t\tclass=\"mt-0 mb-1 jobs-page text-truncate\"",
			"\t\t\t\t\t\t\t\t\ttitle=\"{{ jo.job_title|e }}\"",
			"\t\t\t\t\t\t\t\t>",
			"\t\t\t\t\t\t\t\t\t{{ jo.job_title|e }}",
		],
	},
	{
		"id": "M22e",
		"file": "hrms/templates/generators/job_opening.html",
		"mode": "replace",
		"old": "\t\t\t\t\t\thref=\"/{{ job_application_route if job_application_route else 'job_application' }}/new?job_title={{ name }}\"",
		"new": "\t\t\t\t\t\thref=\"/{{ (job_application_route if job_application_route else 'job_application')|e }}/new?job_title={{ name|e }}\"{# TREEO-SEC M22e #}",
	},
	{
		"id": "M22f",
		"file": "hrms/templates/generators/job_opening.html",
		"mode": "replace",
		"old": "\t\t\t\t\thref=\"/{{ job_application_route if job_application_route else 'job_application' }}/new?job_title={{ name }}\"",
		"new": "\t\t\t\t\thref=\"/{{ (job_application_route if job_application_route else 'job_application')|e }}/new?job_title={{ name|e }}\"{# TREEO-SEC M22f #}",
	},
	{
		"id": "M23a",
		"file": "hrms/payroll/doctype/salary_slip/salary_slip.py",
		"mode": "append",
		"needs": ["def treeo_only_own_payroll(", "from frappe import _"],
		"lines": [
			"# TREEO-SEC M23a: whitelisted payroll calculators that take an employee argument",
			"# (employee_benefit_application.get_max_benefits & co.) follow the M21 rule: only",
			"# Administrator / HR Manager / HR User (System Manager with its own grant) for anyone,",
			"# everyone else only for their own Employee.",
			"def treeo_assert_own_payroll(doctype, employee, user=None):",
			"\tuser = user or frappe.session.user",
			"\tif not treeo_only_own_payroll(doctype, user):",
			"\t\treturn",
			"\tif employee and frappe.db.get_value(\"Employee\", employee, \"user_id\") == user:",
			"\t\treturn",
			"\tfrappe.throw(_(\"Not permitted to read payroll data of another employee.\"), frappe.PermissionError)",
		],
	},
	{
		"id": "M23b",
		"file": "hrms/payroll/doctype/employee_benefit_application/employee_benefit_application.py",
		"mode": "insert",
		"func": "def get_max_benefits(",
		"after": '\tfrappe.has_permission("Employee", "read", employee, throw=True)  # TREEO-SEC M5e',
		"needs_file": {"hrms/payroll/doctype/salary_slip/salary_slip.py": ["def treeo_assert_own_payroll("]},
		"lines": [
			"\tfrom hrms.payroll.doctype.salary_slip.salary_slip import treeo_assert_own_payroll  # TREEO-SEC M23b",
			"",
			"\ttreeo_assert_own_payroll(\"Employee Benefit Application\", employee)",
		],
	},
	{
		"id": "M23c",
		"file": "hrms/payroll/doctype/employee_benefit_application/employee_benefit_application.py",
		"mode": "insert",
		"func": "def get_max_benefits_remaining(",
		"after": '\tfrappe.has_permission("Employee", "read", employee, throw=True)  # TREEO-SEC M5f',
		"needs_file": {"hrms/payroll/doctype/salary_slip/salary_slip.py": ["def treeo_assert_own_payroll("]},
		"lines": [
			"\tfrom hrms.payroll.doctype.salary_slip.salary_slip import treeo_assert_own_payroll  # TREEO-SEC M23c",
			"",
			"\ttreeo_assert_own_payroll(\"Employee Benefit Application\", employee)",
		],
	},
	{
		"id": "M23d",
		"file": "hrms/payroll/doctype/employee_benefit_application/employee_benefit_application.py",
		"mode": "insert",
		"func": "def get_earning_components_max_benefits(",
		"after": '\tfrappe.has_permission("Employee", "read", employee, throw=True)  # TREEO-SEC M5g',
		"needs_file": {"hrms/payroll/doctype/salary_slip/salary_slip.py": ["def treeo_assert_own_payroll("]},
		"lines": [
			"\tfrom hrms.payroll.doctype.salary_slip.salary_slip import treeo_assert_own_payroll  # TREEO-SEC M23d",
			"",
			"\ttreeo_assert_own_payroll(\"Employee Benefit Application\", employee)",
		],
	},
	{
		"id": "M24",
		"file": "hrms/hr/doctype/exit_interview/exit_interview.py",
		"mode": "insert",
		"func": "def send_exit_questionnaire(",
		"before": "\temail_success = []",
		"lines": [
			"\t# TREEO-SEC M24: email permission on every selected interview, before anything is sent",
			"\t# (upstream has no check: any user could mail exit questionnaires and learn who leaves)",
			"\tfor exit_interview in interviews:",
			"\t\tfrappe.has_permission(\"Exit Interview\", \"email\", exit_interview.get(\"name\"), throw=True)",
			"",
		],
	},
	{
		"id": "M25a",
		"file": "hrms/hr/doctype/job_applicant/job_applicant.py",
		"mode": "insert",
		"func": "\tdef validate(self):",
		"needs": ["from frappe import _"],
		"lines": [
			"\t\t# TREEO-SEC M25a: the desk opens / embeds resume_link; only http(s) URLs",
			"\t\tif self.resume_link and not self.resume_link.strip().lower().startswith((\"http://\", \"https://\")):",
			"\t\t\tfrappe.throw(_(\"Resume Link must start with http:// or https://.\"), frappe.ValidationError)",
		],
	},
	{
		"id": "M25b",
		"file": "hrms/hr/doctype/employee_referral/employee_referral.py",
		"mode": "insert",
		"func": "\tdef validate(self):",
		"needs": ["from frappe import _"],
		"lines": [
			"\t\t# TREEO-SEC M25b: copied into the Job Applicant's resume_link; only http(s) URLs",
			"\t\tif self.resume_link and not self.resume_link.strip().lower().startswith((\"http://\", \"https://\")):",
			"\t\t\tfrappe.throw(_(\"Resume Link must start with http:// or https://.\"), frappe.ValidationError)",
		],
	},
	{
		"id": "M26",
		"file": "hrms/api/__init__.py",
		"mode": "insert",
		"func": "def upload_base64_file(",
		"before": "\tdecoded_content = base64.b64decode(content)",
		"lines": [
			"\t# TREEO-SEC M26: check write permission before decoding (upstream decoded any payload first)",
			"\tfrappe.has_permission(dt, \"write\", dn, throw=True)",
		],
	},
	{
		"id": "M27a",
		"file": "hrms/hr/utils.py",
		"mode": "append",
		"needs": ["import frappe"],
		"lines": [
			"# TREEO-SEC M27a: frappe v15 checks User Permissions for write / submit / cancel / amend /",
			"# delete only against the values being saved, so a user scoped to their own Employee could",
			"# PUT a colleague's draft with employee set to themselves. Registered as a has_permission",
			"# hook (M27b), this also requires User Permission access to the STORED document. It only",
			"# denies (False) or defers (None); read, create and new documents are unchanged.",
			"TREEO_STORED_UP_PTYPES = {\"write\", \"submit\", \"cancel\", \"amend\", \"delete\"}",
			"",
			"",
			"def treeo_stored_up_has_permission(doc, ptype=None, user=None, debug=False):",
			"\tif ptype not in TREEO_STORED_UP_PTYPES or not doc.get(\"name\") or doc.get(\"__islocal\"):",
			"\t\treturn None",
			"\tuser = user or frappe.session.user",
			"\tif user == \"Administrator\" or not frappe.db.exists(doc.doctype, doc.get(\"name\")):",
			"\t\treturn None",
			"\tfrom frappe.permissions import has_user_permission",
			"",
			"\tstored = frappe.get_doc(doc.doctype, doc.get(\"name\"))",
			"\treturn None if has_user_permission(stored, user, debug=debug, ptype=ptype) else False",
		],
	},
	{
		"id": "M27b",
		"file": "hrms/hooks.py",
		"mode": "append",
		"needs": ["TREEO-SEC M21b"],
		"needs_file": {"hrms/hr/utils.py": ["def treeo_stored_up_has_permission("]},
		"lines": [
			"# TREEO-SEC M27b: self-service doctypes also need User Permission access to the stored",
			"# document for write / submit / cancel / amend / delete (M27a). Appended after any existing",
			"# hook for the doctype, never replacing it: frappe runs the hooks in reverse order and the",
			"# first non-None answer wins, and every TREEO hook only returns None or False.",
			"for _treeo_dt in (",
			"\t\"Employee Grievance\",",
			"\t\"Expense Claim\",",
			"\t\"Employee Advance\",",
			"\t\"Leave Application\",",
			"\t\"Leave Encashment\",",
			"\t\"Attendance Request\",",
			"\t\"Compensatory Leave Request\",",
			"\t\"Shift Request\",",
			"\t\"Appraisal\",",
			"\t\"Employee Performance Feedback\",",
			"\t\"Employee Referral\",",
			"\t\"Training Feedback\",",
			"):",
			"\t_treeo_prev = has_permission.get(_treeo_dt) or []",
			"\thas_permission[_treeo_dt] = ([_treeo_prev] if isinstance(_treeo_prev, str) else list(_treeo_prev)) + [",
			"\t\t\"hrms.hr.utils.treeo_stored_up_has_permission\"",
			"\t]",
		],
	},
	{
		"id": "M27d",
		"file": "hrms/hr/doctype/vehicle_log/vehicle_log.py",
		"mode": "insert",
		"func": "def make_expense_claim(",
		"lines": ['\tfrappe.has_permission("Vehicle Log", "read", docname, throw=True)  # TREEO-SEC M27d'],
	},
	{
		"id": "M27e",
		"file": "hrms/api/roster.py",
		"mode": "insert",
		"func": "def get_schedule_from_assignment(",
		"lines": [
			"\tfrappe.has_permission(  # TREEO-SEC M27e",
			"\t\t\"Shift Schedule Assignment\", \"read\", shift_schedule_assignment, throw=True",
			"\t)",
		],
	},
	{
		"id": "M27f",
		"file": "hrms/hr/doctype/training_result/training_result.py",
		"mode": "insert",
		"func": "def get_employees(",
		"lines": ['\tfrappe.has_permission("Training Event", "read", training_event, throw=True)  # TREEO-SEC M27f'],
	},
	{
		"id": "M27g",
		"file": "hrms/hr/doctype/staffing_plan/staffing_plan.py",
		"mode": "insert",
		"func": "def get_designation_counts(",
		"lines": [
			"\t# TREEO-SEC M27g: headcount per designation / company; same gate as M14c",
			'\tfrappe.has_permission("Staffing Plan", "read", throw=True)',
		],
	},
	{
		"id": "M27h",
		"file": "hrms/payroll/doctype/salary_withholding/salary_withholding.py",
		"mode": "insert",
		"func": "def get_payroll_frequency(",
		"needs_file": {"hrms/payroll/doctype/salary_slip/salary_slip.py": ["def treeo_assert_own_payroll("]},
		"lines": [
			"\tfrom hrms.payroll.doctype.salary_slip.salary_slip import treeo_assert_own_payroll  # TREEO-SEC M27h",
			"",
			"\ttreeo_assert_own_payroll(\"Salary Withholding\", employee)",
		],
	},
	{
		"id": "M27i",
		"file": "hrms/payroll/doctype/salary_structure_assignment/salary_structure_assignment.py",
		"mode": "insert",
		"func": "def get_employee_currency(",
		"needs_file": {"hrms/payroll/doctype/salary_slip/salary_slip.py": ["def treeo_assert_own_payroll("]},
		"lines": [
			"\tfrom hrms.payroll.doctype.salary_slip.salary_slip import treeo_assert_own_payroll  # TREEO-SEC M27i",
			"",
			"\ttreeo_assert_own_payroll(\"Salary Structure Assignment\", employee)",
		],
	},
	{
		"id": "M27j",
		"file": "hrms/hr/doctype/expense_claim/expense_claim.py",
		"mode": "insert",
		"func": "def get_expense_claim(",
		"before": '\tadvance_currency = frappe.db.get_value("Employee Advance", employee_advance_name, "currency")',
		"lines": [
			"\t# TREEO-SEC M27j: the claim is built from the advance's amounts; read access to it first",
			'\tfrappe.has_permission("Employee Advance", "read", employee_advance_name, throw=True)',
		],
	},
	{
		"id": "M28",
		"file": "hrms/payroll/doctype/salary_component/salary_component.py",
		"mode": "insert",
		"func": "\tdef update_salary_structures(",
		"needs": ["from frappe import _"],
		"lines": [
			"\t\t# TREEO-SEC M28: run_doc_method checks only read (Employee has it); this method writes a",
			"\t\t# caller-chosen field into every Salary Structure Detail row through db_update_all",
			"\t\tself.check_permission(\"write\")",
			"\t\tfrappe.has_permission(\"Salary Structure\", \"write\", throw=True)",
			"\t\tif field not in (\"condition\", \"formula\"):",
			"\t\t\tfrappe.throw(_(\"Unsupported field.\"), frappe.ValidationError)",
			"",
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
skipped_ids = []
# F12: a skip of one of these leaves cross-employee payroll / checkin data or a role-gated
# action open, so it stops the container instead of only warning
CRITICAL = ("M10", "M12", "M15", "M21a", "M21b", "M21c", "M24", "M27a", "M27b", "M28")


def warn(pid, msg):
	counts["skipped"] += 1
	skipped_ids.append(pid)
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


def apply_append(p, lines):
	while lines and lines[-1] == "":
		lines.pop()
	lines[len(lines) :] = ["", ""] + p["lines"] + [""]
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
	other_missing = [
		f"{f}: {n}"
		for f, ns in p.get("needs_file", {}).items()
		for n in ns
		if not (app / f).is_file() or n not in (app / f).read_text()
	]
	if other_missing:
		warn(pid, f"prerequisite missing ({other_missing})")
		continue

	lines = text.split("\n")
	apply = {"insert": apply_insert, "replace": apply_replace, "block": apply_block, "append": apply_append}[
		p["mode"]
	]
	err = apply(p, lines)
	if err:
		warn(pid, f"{p['file']}: {err}")
		continue

	new_text = "\n".join(lines)
	if path.suffix == ".py":
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
critical = [i for i in CRITICAL if i in skipped_ids]
if critical:
	print(f"SECURITY ERROR: critical security patch(es) {', '.join(critical)} skipped - refusing to continue.")
	sys.exit(4)
PY
rc=$?
if [ $rc -eq 4 ]; then
  exit 3  # F12: a critical patch was skipped (SECURITY ERROR printed above)
fi
if [ $rc -ne 0 ]; then
  [ $rc -eq 3 ] || echo "SECURITY ERROR: security patch injector crashed (exit $rc); patches may NOT be applied."
  exit 1
fi

exit 0
