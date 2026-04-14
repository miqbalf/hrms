import frappe
from frappe.model.rename_doc import rename_doc


def execute():
	if frappe.db.has_table("Interview Round"):
		for interview_round, interview_type in frappe.get_all(
			"Interview Round", fields=["name", "interview_type"], as_list=True
		):
			rename_doc("Interview Type", interview_type, interview_round)
