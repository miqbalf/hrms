from unittest.mock import MagicMock, patch

import frappe

import hrms.utils as hrms_utils
from hrms.hr.doctype.leave_application.leave_calendar_sync import resync_employee_leaves
from hrms.tests.utils import HRMSTestSuite


class TestGetCountry(HRMSTestSuite):
	def setUp(self):
		hrms_utils.country_info.clear()
		self._request_ip = getattr(frappe.local, "request_ip", None)

	def tearDown(self):
		frappe.local.request_ip = self._request_ip
		hrms_utils.country_info.clear()

	def _response(self, payload):
		res = MagicMock()
		res.json.return_value = payload
		return res

	def test_invalid_ip_never_reaches_upstream(self):
		for bad in ("1.2.3.4/../../admin", "evil.example?x=", "", None):
			frappe.local.request_ip = bad
			with patch.object(hrms_utils.requests, "get") as get:
				self.assertEqual(hrms_utils.get_country(), {})
				get.assert_not_called()

	def test_params_and_timeout_are_used(self):
		frappe.local.request_ip = "8.8.8.8"
		with patch.object(hrms_utils.requests, "get", return_value=self._response({"countryCode": "US"})) as get:
			self.assertEqual(hrms_utils.get_country(), {"countryCode": "US"})
		args, kwargs = get.call_args
		self.assertEqual(args[0], "https://pro.ip-api.com/json/8.8.8.8")
		self.assertIn("params", kwargs)
		self.assertIn("fields", kwargs["params"])
		self.assertEqual(kwargs["timeout"], hrms_utils.COUNTRY_LOOKUP_TIMEOUT)

	def test_upstream_failure_returns_empty(self):
		frappe.local.request_ip = "8.8.4.4"
		with patch.object(hrms_utils.requests, "get", side_effect=Exception("timeout")):
			self.assertEqual(hrms_utils.get_country(), {})

	def test_cache_is_bounded(self):
		with patch.object(hrms_utils, "COUNTRY_INFO_CACHE_SIZE", 3), patch.object(
			hrms_utils.requests, "get", return_value=self._response({})
		):
			for i in range(10):
				frappe.local.request_ip = f"10.0.0.{i}"
				hrms_utils.get_country()
		self.assertEqual(len(hrms_utils.country_info), 3)
		self.assertIn("10.0.0.9", hrms_utils.country_info)
		self.assertNotIn("10.0.0.0", hrms_utils.country_info)


class TestResyncEmployeeLeavesPermission(HRMSTestSuite):
	def tearDown(self):
		frappe.set_user("Administrator")

	def test_guest_is_rejected(self):
		frappe.set_user("Guest")
		with self.assertRaises(frappe.PermissionError):
			resync_employee_leaves("HR-EMP-00001")
