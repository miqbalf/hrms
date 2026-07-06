from collections.abc import Generator

import requests

import frappe
from frappe.utils import add_days, date_diff, today

country_info = {}


@frappe.whitelist(allow_guest=True)
def get_country(fields: list | None = None) -> dict:
	global country_info
	ip = frappe.local.request_ip

	if ip not in country_info:
		fields = ["countryCode", "country", "regionName", "city"]
		res = requests.get(
			"https://pro.ip-api.com/json/{ip}?key={key}&fields={fields}".format(
				ip=ip, key=frappe.conf.get("ip-api-key"), fields=",".join(fields)
			)
		)

		try:
			country_info[ip] = res.json()

		except Exception:
			country_info[ip] = {}

	return country_info[ip]


def get_date_range(start_date: str, end_date: str) -> list[str]:
	"""returns list of dates between start and end dates"""
	no_of_days = date_diff(end_date, start_date) + 1
	return [add_days(start_date, i) for i in range(no_of_days)]


def generate_date_range(start_date: str, end_date: str, reverse: bool = False) -> Generator[str, None, None]:
	no_of_days = date_diff(end_date, start_date) + 1

	date_field = end_date if reverse else start_date
	direction = -1 if reverse else 1

	for n in range(no_of_days):
		yield add_days(date_field, direction * n)


def is_half_holiday(holiday_list: str, date: str | None = None) -> bool:
	if date is None:
		date = today()
	if holiday_list:
		from frappe.model import default_fields

		meta = frappe.get_meta("Holiday")
		if meta.has_field("is_half_day"):
			return bool(
				frappe.db.exists(
					"Holiday", {"parent": holiday_list, "holiday_date": date, "is_half_day": 1}, cache=True
				)
			)
	return False


def get_employee_email(employee_id: str) -> str | None:
	employee_emails = frappe.db.get_value(
		"Employee",
		employee_id,
		["prefered_email", "user_id", "company_email", "personal_email"],
		as_dict=True,
	)

	return (
		employee_emails.prefered_email
		or employee_emails.user_id
		or employee_emails.company_email
		or employee_emails.personal_email
	)


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
