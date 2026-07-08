"""
Patch to:
1. Add custom fields for Google Calendar sync on Leave Application and HR Settings
2. Add Google Calendar scopes to the Google Social Login Key
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

    # Add Calendar API scope to Google Social Login Key
    add_calendar_scopes_to_google_provider()


def add_calendar_scopes_to_google_provider():
    """Add Google Calendar API scopes to the existing Google Social Login Key."""
    import frappe

    calendar_scopes = [
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/calendar",
    ]

    google_providers = frappe.get_all(
        "Social Login Key",
        filters={"enable_social_login": 1},
        fields=["name", "provider_name", "scopes"],
    )

    for provider in google_providers:
        if "google" not in (provider.get("provider_name") or "").lower():
            continue

        existing_scopes = (provider.get("scopes") or "").strip().split()
        updated = False

        for scope in calendar_scopes:
            if scope not in existing_scopes:
                existing_scopes.append(scope)
                updated = True

        if updated:
            frappe.db.set_value(
                "Social Login Key",
                provider.name,
                "scopes",
                " ".join(existing_scopes),
            )
            print(
                f"✅ Added Calendar scopes to Google Social Login Key '{provider.name}'.\n"
                f"   New scopes: {' '.join(existing_scopes)}\n"
                f"   ⚠️  Each employee must re-login with Google for scopes to take effect."
            )

    if not google_providers:
        print("⚠️  No Google Social Login Key found — skipping scope update.")
