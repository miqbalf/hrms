import frappe
from frappe.utils import today


def is_half_holiday(holiday_list: str, date: str | None = None) -> bool:
	if date is None:
		date = today()
	if holiday_list:
		meta = frappe.get_meta("Holiday")
		if meta.has_field("is_half_day"):
			return bool(
				frappe.db.exists(
					"Holiday", {"parent": holiday_list, "holiday_date": date, "is_half_day": 1}, cache=True
				)
			)
	return False


def apply_branding():
	"""Apply TREEO branding to all relevant DocTypes."""
	frappe.db.set_single_value("Website Settings", "brand_html",
		'<span class="brand-label">TREEO HR system</span>')
	frappe.db.set_single_value("Website Settings", "tagline", "TREEO HR system")
	frappe.db.set_single_value("Website Settings", "app_logo", "/files/treeo_logo.png")
	frappe.db.set_single_value("Website Settings", "favicon", "/files/favicon.png")
	frappe.db.set_single_value("Navbar Settings", "app_logo", "/files/treeo_logo.png")
	frappe.db.set_single_value("System Settings", "app_name", "TREEO HR system")
	frappe.db.commit()
