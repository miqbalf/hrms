import frappe

def send_instantly(doc, method):
	"""Hook to send Email Queue items instantly on database commit."""
	if doc.status == "Not Sent":
		frappe.db.after_commit.add(doc.send)
