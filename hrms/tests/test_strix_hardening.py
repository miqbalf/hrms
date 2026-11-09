"""Regression tests for the Strix 2026-11 findings (M1-M5).

Production runs upstream frappe/hrms v15 with these fixes injected by
docker/assets/inject_security_patches.sh; the same checks live in this repo's
source (search for "TREEO-SEC"). These tests need a Frappe bench to run.
"""

import json
from unittest.mock import MagicMock, patch

import frappe
from frappe.utils import add_days, add_to_date, getdate, today

from erpnext.setup.doctype.employee.test_employee import make_employee

from hrms.api import (
	MAX_CALENDAR_RANGE_DAYS,
	get_attendance_calendar_events,
	get_company_cost_center_and_expense_account,
	get_workflow,
)
from hrms.hr.doctype.expense_claim.expense_claim import get_advances
from hrms.hr.doctype.leave_ledger_entry.leave_ledger_entry import expire_allocation
from hrms.hr.page.team_updates.team_updates import get_data as get_team_updates
from hrms.overrides import employee_payment_entry
from hrms.tests.utils import HRMSTestSuite

NO_ROLE_USER = "strix-no-role@example.com"


def _no_role_user() -> str:
	if not frappe.db.exists("User", NO_ROLE_USER):
		frappe.get_doc(
			{
				"doctype": "User",
				"email": NO_ROLE_USER,
				"first_name": "Strix",
				"user_type": "Website User",
				"send_welcome_email": 0,
			}
		).insert(ignore_permissions=True)
	return NO_ROLE_USER


class TestStrixHardening(HRMSTestSuite):
	def tearDown(self):
		frappe.set_user("Administrator")
		frappe.db.rollback()

	# M1
	def test_calendar_range_is_bounded(self):
		start = getdate("2026-01-01")
		with self.assertRaises(frappe.ValidationError):
			get_attendance_calendar_events(str(start), str(add_days(start, MAX_CALENDAR_RANGE_DAYS + 1)))
		with self.assertRaises(frappe.ValidationError):
			get_attendance_calendar_events("0001-01-01", "9999-12-31")
		with self.assertRaises(frappe.ValidationError):
			get_attendance_calendar_events(str(start), str(add_days(start, -1)))

	# M2
	def test_workflow_needs_doctype_read(self):
		frappe.set_user(_no_role_user())
		with self.assertRaises(frappe.PermissionError):
			get_workflow("Leave Application")

	def test_company_accounts_need_company_read(self):
		company = frappe.db.get_value("Company", {}, "name")
		frappe.set_user(_no_role_user())
		with self.assertRaises(frappe.PermissionError):
			get_company_cost_center_and_expense_account(company)

	# M3
	def test_team_updates_role_gate(self):
		frappe.set_user(_no_role_user())
		with self.assertRaises(frappe.PermissionError):
			get_team_updates()

	# M4
	def test_expire_allocation_needs_write(self):
		employee = make_employee("strix-leave@example.com", company="_Test Company")
		allocation = frappe.get_doc(
			{
				"doctype": "Leave Allocation",
				"employee": employee,
				"leave_type": "_Test Leave Type",
				"from_date": today(),
				"to_date": add_to_date(today(), days=30),
				"new_leaves_allocated": 5,
			}
		).submit()

		frappe.set_user(_no_role_user())
		# a forged client payload must not bypass the check
		with self.assertRaises(frappe.PermissionError):
			expire_allocation(json.dumps({"name": allocation.name, "employee": "anything"}))

		frappe.set_user("Administrator")
		expire_allocation(json.dumps({"name": allocation.name}))
		self.assertEqual(frappe.db.get_value("Leave Allocation", allocation.name, "expired"), 1)

	# M5
	def test_payment_helpers_check_read_permission(self):
		doc = MagicMock()
		doc.check_permission.side_effect = frappe.PermissionError
		with patch.object(employee_payment_entry.frappe, "get_doc", return_value=doc):
			with self.assertRaises(frappe.PermissionError):
				employee_payment_entry.get_payment_entry_for_employee("Expense Claim", "X")
			with self.assertRaises(frappe.PermissionError):
				employee_payment_entry.get_reference_details_for_employee("Expense Claim", "X", "INR")
		doc.check_permission.assert_called_with("read")

	def test_get_advances_checks_employee(self):
		employee = make_employee("strix-advance@example.com", company="_Test Company")
		frappe.set_user(_no_role_user())
		with self.assertRaises(frappe.PermissionError):
			get_advances(json.dumps({"doctype": "Expense Claim", "employee": employee}))
