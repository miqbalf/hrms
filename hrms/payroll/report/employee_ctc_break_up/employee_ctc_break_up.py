# Copyright (c) 2026, Frappe Technologies Pvt. Ltd. and contributors
# For license information, please see license.txt

import frappe
from frappe import _
from frappe.utils import flt

from hrms.payroll.doctype.salary_structure.salary_structure import make_salary_slip


class SalaryBreakupReport:
	def __init__(self, employee, salary_structure_assignment):
		self.employee = employee
		self.ctc = frappe.db.get_value("Employee", employee, "ctc")
		self.salary_structure, self.currency = frappe.get_value(
			"Salary Structure Assignment", salary_structure_assignment, ["salary_structure", "currency"]
		)
		self.salary_slip = make_salary_slip(
			self.salary_structure, employee=self.employee, for_preview=1, as_print=False
		)
		self.net_pay = self.salary_slip.net_pay
		self.gross_pay = self.salary_slip.gross_pay
		self.payroll_frequency = self.salary_slip.payroll_frequency
		self.cycle_multiplier = {
			"Monthly": 12,
			"Fortnightly": 24,
			"Bimonthly": 6,
			"Weekly": 52,
			"Daily": 365,
		}.get(self.payroll_frequency)
		self.salary_components = []
		self.earning_components = []
		self.deduction_components = []
		self.tax_components = []
		self.total_net_earnings = []
		self.total_gross_earnings = []

	def get_data(self):
		self.set_salary_component_details()
		self.calculate_yearly_amounts_and_percent_of_ctc()
		self.indent_salary_components()
		self.separate_salary_components_by_type()
		self.set_type_and_formula()
		self.set_totals_row_for_component_types()
		self.set_net_and_gross_earning_rows()

		return (
			self.earning_components
			+ self.deduction_components
			+ self.tax_components
			+ self.total_net_earnings
			+ self.total_gross_earnings
		)

	def set_salary_component_details(self):
		salary_component_details = frappe.db.get_all(
			"Salary Detail",
			filters={"parent": self.salary_structure},
			fields=["salary_component", "amount_based_on_formula", "formula"],
		)

		self.salary_components = [
			{
				"salary_component": component.salary_component,
				"per_cycle": component.amount,
				"abbr": component.abbr,
				"is_tax_component": component.variable_based_on_taxable_salary,
				"component_type": component.parentfield,
			}
			for component in self.salary_slip.earnings + self.salary_slip.deductions
		]

		for component in self.salary_components:
			component_details = next(
				(
					detail
					for detail in salary_component_details
					if component.get("salary_component") == detail.salary_component
				),
				{},
			)
			component.update(component_details)

	def calculate_yearly_amounts_and_percent_of_ctc(self):
		for component in self.salary_components:
			annual_amount = component.get("per_cycle", 0) * self.cycle_multiplier
			component.update(
				{
					"annual": flt(annual_amount, 2),
					"percent_of_ctc": self.calculate_percent_of_ctc(annual_amount),
				}
			)

	def separate_salary_components_by_type(self):
		self.earning_components = [
			component for component in self.salary_components if component.get("component_type") == "earnings"
		]
		self.deduction_components = [
			component
			for component in self.salary_components
			if component.get("component_type") == "deductions" and not component.get("is_tax_component")
		]
		self.tax_components = [
			component for component in self.salary_components if component.get("is_tax_component")
		]

	def set_type_and_formula(self):
		for component in self.earning_components + self.deduction_components:
			component["type"] = "Formula" if component.get("amount_based_on_formula") else "Fixed"
			component["formula"] = (
				component.get("formula") or "-"
				if component.get("amount_based_on_formula")
				else component.get("per_cycle") or "-"
			)

	def set_totals_row_for_component_types(self):
		def calculate_total(period, components):
			total = 0
			for component in components:
				total += component.get(period)
			return total

		def set_totals_row(component_type):
			components = {
				"Earnings": self.earning_components,
				"Deductions": self.deduction_components,
				"Tax Deductions": self.tax_components,
			}.get(component_type)
			totals_row = {
				"salary_component": component_type,
				"type": "",
				"formula": "",
				"bold": True,
				"per_cycle": calculate_total("per_cycle", components),
				"annual": calculate_total("annual", components),
				"percent_of_ctc": self.calculate_percent_of_ctc(calculate_total("annual", components)),
			}
			components.insert(0, totals_row)

		for component_type in ("Earnings", "Deductions", "Tax Deductions"):
			set_totals_row(component_type)

	def set_net_and_gross_earning_rows(self):
		self.total_net_earnings = [
			{
				"salary_component": "Total Net Earnings",
				"type": "",
				"formula": "",
				"per_cycle": self.net_pay,
				"annual": self.net_pay * self.cycle_multiplier,
				"percent_of_ctc": self.calculate_percent_of_ctc(self.net_pay * self.cycle_multiplier),
				"bold": True,
			}
		]
		self.total_gross_earnings = [
			{
				"salary_component": "Total Gross Earnings",
				"type": "",
				"formula": "",
				"per_cycle": self.gross_pay,
				"annual": self.gross_pay * self.cycle_multiplier,
				"percent_of_ctc": self.calculate_percent_of_ctc(self.gross_pay * self.cycle_multiplier),
				"bold": True,
			}
		]

	def calculate_percent_of_ctc(self, amount):
		return flt(amount * 100 / self.ctc, 2)

	def indent_salary_components(self):
		for component in self.salary_components:
			component["indent"] = 1

	def get_summary(self):
		per_cycle_ctc = flt(self.ctc / self.cycle_multiplier, 2)
		return [
			{"value": self.ctc, "label": _("Annual CTC"), "datatype": "Currency", "currency": self.currency},
			{
				"value": per_cycle_ctc,
				"label": _(f"{self.payroll_frequency} CTC"),
				"datatype": "Currency",
				"currency": self.currency,
			},
			{
				"value": self.gross_pay,
				"label": _(f"{self.payroll_frequency} Gross Pay"),
				"datatype": "Currency",
				"currency": self.currency,
			},
			{
				"value": self.net_pay,
				"label": _(f"{self.payroll_frequency} Net Pay"),
				"datatype": "Currency",
				"currency": self.currency,
			},
		]

	def get_columns(self) -> list[dict]:
		"""Return columns for the report.

		One field definition per column, just like a DocType field definition.
		"""
		return [
			{
				"label": _("Component"),
				"fieldname": "salary_component",
				"fieldtype": "Data",
				"width": 300,
			},
			{
				"label": _("Type"),
				"fieldname": "type",
				"fieldtype": "Data",
				"width": 200,
			},
			{
				"label": _("Formula/Amount"),
				"fieldname": "formula",
				"fieldtype": "Data",
				"width": 200,
			},
			{
				"label": _(self.payroll_frequency),
				"fieldname": "per_cycle",
				"fieldtype": "Currency",
				"width": 200,
				"options": "currency",
			},
			{
				"label": _("Annual"),
				"fieldname": "annual",
				"fieldtype": "Currency",
				"width": 200,
				"options": "currency",
			},
			{
				"label": _("Percent of CTC (%)"),
				"fieldname": "percent_of_ctc",
				"fieldtype": "Percent",
				"width": 200,
			},
			{
				"fieldname": "currency",
				"label": _("Currency"),
				"fieldtype": "Link",
				"options": "Currency",
				"hidden": 1,
				"value": self.currency,
			},
		]


def execute(filters: dict | None = None):
	"""Return columns and data for the report.

	This is the main entry point for the report. It accepts the filters as a
	dictionary and should return columns and data. It is called by the framework
	every time the report is refreshed or a filter is updated.
	"""

	salary_structure_assignment = filters.get("salary_structure_assignment")
	employee = filters.get("employee")
	salary_breakup_report = SalaryBreakupReport(employee, salary_structure_assignment)

	data = salary_breakup_report.get_data()
	summary = salary_breakup_report.get_summary()
	columns = salary_breakup_report.get_columns()

	return columns, data, None, None, summary
