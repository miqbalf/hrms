import frappe


def execute():
	if frappe.db.table_exists("Workspace Sidebar") and frappe.db.has_column("Workspace Sidebar", "standard"):
		if frappe.db.exists("Workspace Sidebar", "People"):
			frappe.db.set_value("Workspace Sidebar", "People", "standard", 1)
