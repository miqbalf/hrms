"""
Patch to add custom fields for Google Calendar sync on Leave Application
and HR Settings.
"""

from frappe.custom.doctype.custom_field.custom_field import create_custom_field


def execute():
    # Fields for Leave Application
    create_custom_field(
        "Leave Application",
        {
            "fieldname": "google_calendar_synced",
            "fieldtype": "Check",
            "label": "Synced to Google Calendar",
            "default": 0,
            "read_only": 1,
            "no_copy": 1,
            "insert_after": "status",
        },
    )

    create_custom_field(
        "Leave Application",
        {
            "fieldname": "google_calendar_event_id",
            "fieldtype": "Data",
            "label": "Google Calendar Event ID",
            "read_only": 1,
            "no_copy": 1,
            "hidden": 1,
            "insert_after": "google_calendar_synced",
        },
    )

    # Field for HR Settings
    create_custom_field(
        "HR Settings",
        {
            "fieldname": "enable_google_calendar_sync",
            "fieldtype": "Check",
            "label": "Enable Google Calendar Sync for Approved Leaves",
            "description": "When checked, approved leave applications will be synced to the employee's Google Calendar.",
            "default": 0,
            "insert_after": "show_leaves_of_all_department_members_in_calendar",
        },
    )
