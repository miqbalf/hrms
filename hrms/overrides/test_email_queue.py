# Copyright (c) 2026, Frappe Technologies Pvt. Ltd. and Contributors
# License: GNU General Public License v3. See license.txt

import json

import frappe

from hrms.overrides.email_queue import EmailQueue, filter_print_attachments_for_cancelled_docs
from hrms.tests.utils import HRMSTestSuite


class TestEmailQueueCancelledPrint(HRMSTestSuite):
	def test_filter_drops_cancelled_print_keeps_others(self):
		todo = frappe.get_doc(
			{
				"doctype": "ToDo",
				"description": "email queue cancelled print test",
			}
		).insert(ignore_permissions=True)
		# ToDo is not submittable; simulate cancelled via SQL for filter unit test
		frappe.db.set_value("ToDo", todo.name, "docstatus", 2, update_modified=False)

		attachments = [
			{"fid": "FILE-1", "file_url": "/files/a.pdf"},
			{
				"print_format_attachment": 1,
				"doctype": "ToDo",
				"name": todo.name,
				"print_format": "Standard",
			},
			{
				"print_format_attachment": 1,
				"doctype": "ToDo",
				"name": "Nonexistent",
				"print_format": "Standard",
			},
		]

		filtered = filter_print_attachments_for_cancelled_docs(attachments)
		self.assertEqual(len(filtered), 2)
		self.assertEqual(filtered[0].get("fid"), "FILE-1")
		self.assertEqual(filtered[1].get("name"), "Nonexistent")

	def test_email_queue_validate_strips_cancelled_print(self):
		todo = frappe.get_doc(
			{
				"doctype": "ToDo",
				"description": "email queue validate strip test",
			}
		).insert(ignore_permissions=True)
		frappe.db.set_value("ToDo", todo.name, "docstatus", 2, update_modified=False)

		queue = frappe.new_doc("Email Queue")
		self.assertTrue(isinstance(queue, EmailQueue))
		queue.sender = "Administrator"
		queue.message = "test"
		queue.attachments = json.dumps(
			[
				{
					"print_format_attachment": 1,
					"doctype": "ToDo",
					"name": todo.name,
					"print_format": "Standard",
				}
			]
		)
		queue.append("recipients", {"recipient": "test@example.com"})
		queue.insert(ignore_permissions=True)

		self.assertEqual(queue.attachments_list, [])
