# Copyright (c) 2026, Frappe Technologies Pvt. Ltd. and Contributors
# License: GNU General Public License v3. See license.txt

from __future__ import annotations

import json

import frappe
from frappe.email.doctype.email_queue.email_queue import EmailQueue as CoreEmailQueue
from frappe.email.doctype.email_queue.email_queue import SendMailContext
from frappe.utils import cint


def is_cancelled_print_attachment(attachment: dict) -> bool:
	"""Return True when attachment would call attach_print on a cancelled document."""
	if not isinstance(attachment, dict):
		return False
	if cint(attachment.get("print_format_attachment")) != 1:
		return False

	doctype = attachment.get("doctype")
	name = attachment.get("name")
	if not doctype or not name:
		return False
	if not frappe.db.exists(doctype, name):
		return False

	return cint(frappe.db.get_value(doctype, name, "docstatus")) == 2


def filter_print_attachments_for_cancelled_docs(attachments: list) -> list:
	"""Drop print-format attachments for cancelled docs; keep everything else."""
	if not attachments:
		return attachments
	return [attachment for attachment in attachments if not is_cancelled_print_attachment(attachment)]


class EmailQueue(CoreEmailQueue):
	def strip_cancelled_print_attachments(self):
		attachments = self.attachments_list
		if not attachments:
			return

		filtered = filter_print_attachments_for_cancelled_docs(attachments)
		if len(filtered) != len(attachments):
			self.attachments = json.dumps(filtered)

	def validate(self):
		# Document has no validate(); Frappe runs doc-type validate via hooks/_validate.
		self.strip_cancelled_print_attachments()

	def after_insert(self):
		# Send immediately after commit instead of waiting for scheduler flush (~1–4 min).
		if self.status == "Not Sent":
			frappe.db.after_commit.add(self.send)

	def send(self, smtp_server_instance=None, force_send: bool = False):
		# Cover retries of queues created before strip-on-validate existed.
		self.strip_cancelled_print_attachments()
		return super().send(smtp_server_instance=smtp_server_instance, force_send=force_send)


if not getattr(SendMailContext.include_attachments, "_hrms_cancelled_print_patched", False):
	_original_include_attachments = SendMailContext.include_attachments

	def _patched_include_attachments(self, message):
		attachments = self.queue_doc.attachments_list
		filtered = filter_print_attachments_for_cancelled_docs(attachments)
		if len(filtered) != len(attachments):
			self.queue_doc.attachments = json.dumps(filtered)
		return _original_include_attachments(self, message)

	_patched_include_attachments._hrms_cancelled_print_patched = True
	SendMailContext.include_attachments = _patched_include_attachments
