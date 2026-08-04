"""
Google Calendar sync for Leave Applications (Frappe v15).

Uses Frappe's built-in Google Calendar integration for OAuth.
Each employee must have a "Google Calendar" record with Calendar access authorized.
"""

import frappe
from frappe import _
from frappe.utils import getdate, add_days, today


def _notify(message):
    """Show a message to the user, unless we're running in a background sweep."""
    if frappe.flags.get("in_leave_calendar_sweep"):
        return
    frappe.msgprint(message, alert=True)


def sync_leave_to_google_calendar(doc, method=None):
    """
    Sync an approved Leave Application to the employee's Google Calendar.
    Called via doc_events on_submit (only when status == "Approved").
    """
    if not _is_sync_enabled():
        return

    if doc.status != "Approved" or doc.docstatus != 1:
        return

    try:
        service, gcal_id = _get_google_calendar_service(doc)
        if not service:
            return

        event = _build_event_body(doc)

        if doc.get("google_calendar_event_id"):
            # Update existing event
            try:
                service.events().update(
                    calendarId=gcal_id,
                    eventId=doc.google_calendar_event_id,
                    body=event,
                ).execute()
            except Exception:
                # Event might have been deleted externally — recreate
                created = service.events().insert(
                    calendarId=gcal_id,
                    body=event,
                ).execute()
                doc.db_set("google_calendar_event_id", created["id"], update_modified=False)
        else:
            # Create new event
            created = service.events().insert(
                calendarId=gcal_id,
                body=event,
            ).execute()
            doc.db_set("google_calendar_event_id", created["id"], update_modified=False)

        doc.db_set("google_calendar_synced", 1, update_modified=False)
        _notify(_("Synced to Google Calendar for {0}").format(doc.employee_name))

    except Exception as e:
        frappe.log_error(
            title="Leave Calendar Sync Error",
            message=f"Failed to sync leave {doc.name} for {doc.employee}: {str(e)}",
        )


def update_google_calendar_event(doc, method=None):
    """
    Update the Google Calendar event when a Leave Application is modified.
    """
    if not _is_sync_enabled():
        return

    if doc.status != "Approved" or doc.docstatus != 1:
        return

    if not doc.get("google_calendar_event_id"):
        sync_leave_to_google_calendar(doc)
        return

    try:
        service, gcal_id = _get_google_calendar_service(doc)
        if not service:
            return

        event = _build_event_body(doc)
        service.events().update(
            calendarId=gcal_id,
            eventId=doc.google_calendar_event_id,
            body=event,
        ).execute()

    except Exception as e:
        frappe.log_error(
            title="Leave Calendar Sync Update Error",
            message=f"Failed to update event for leave {doc.name}: {str(e)}",
        )


def delete_google_calendar_event(doc, method=None):
    """
    Delete the Google Calendar event when a leave is cancelled or rejected.
    """
    if not _is_sync_enabled():
        return

    event_id = doc.get("google_calendar_event_id")
    if not event_id:
        return

    try:
        service, gcal_id = _get_google_calendar_service(doc)
        if not service:
            return

        try:
            service.events().delete(
                calendarId=gcal_id,
                eventId=event_id,
            ).execute()
        except Exception as e:
            if "not found" not in str(e).lower() and "404" not in str(e):
                raise

        doc.db_set("google_calendar_event_id", None, update_modified=False)
        doc.db_set("google_calendar_synced", 0, update_modified=False)

    except Exception as e:
        frappe.log_error(
            title="Leave Calendar Sync Delete Error",
            message=f"Failed to delete event for leave {doc.name}: {str(e)}",
        )


def _is_sync_enabled() -> bool:
    """Check if Google Calendar sync is enabled in HR Settings."""
    try:
        return bool(
            frappe.db.get_single_value("HR Settings", "enable_google_calendar_sync")
        )
    except Exception:
        return False


def _get_employee_user_id(employee_name: str) -> str | None:
    """Get the Frappe User ID linked to an Employee."""
    return frappe.db.get_value("Employee", employee_name, "user_id")


def _get_google_calendar_service(doc):
    """
    Build a Google Calendar API service using the employee's authorized
    Google Calendar record from Frappe's built-in integration.
    Returns (service, calendar_id) or (None, None).
    """
    from googleapiclient.discovery import build
    import google.oauth2.credentials
    from frappe.integrations.google_oauth import GoogleOAuth

    employee_user = _get_employee_user_id(doc.employee)
    if not employee_user:
        _notify(
            _("Employee {0} has no linked User account. Cannot sync to Google Calendar.").format(
                doc.employee
            )
        )
        return None, None

    # Find the employee's Google Calendar record
    gcal_name = frappe.db.exists(
        "Google Calendar",
        {"user": employee_user, "enable": 1, "push_to_google_calendar": 1},
    )
    if not gcal_name:
        _notify(
            _("Employee {0} has not set up Google Calendar sync. "
              "Please create a Google Calendar record in Desk and authorize it.").format(
                doc.employee_name or doc.employee
            )
        )
        return None, None

    try:
        google_calendar_doc = frappe.get_doc("Google Calendar", gcal_name)
    except frappe.DoesNotExistError:
        return None, None

    if not google_calendar_doc.refresh_token:
        _notify(
            _("Google Calendar for {0} is not authorized. Please click 'Authorize' on the Google Calendar record.").format(
                doc.employee_name or doc.employee
            )
        )
        return None, None

    google_settings = frappe.get_cached_doc("Google Settings")
    if not google_settings.enable or not google_settings.client_id:
        _notify(
            _("Google Settings are not configured. Please set up Google API in Google Settings.")
        )
        return None, None

    try:
        access_token = google_calendar_doc.get_access_token()
    except Exception as e:
        _notify(
            _("Could not get Google Calendar access for {0}: {1}").format(
                doc.employee_name or doc.employee, str(e)
            )
        )
        return None, None

    SCOPES = "https://www.googleapis.com/auth/calendar"

    credentials = google.oauth2.credentials.Credentials(
        token=access_token,
        refresh_token=google_calendar_doc.get_password(
            fieldname="refresh_token", raise_exception=False
        ),
        token_uri=GoogleOAuth.OAUTH_URL,
        client_id=google_settings.client_id,
        client_secret=google_settings.get_password(
            fieldname="client_secret", raise_exception=False
        ),
        scopes=[SCOPES],
    )

    try:
        service = build("calendar", "v3", credentials=credentials, static_discovery=False)
        # Always sync to the employee's primary calendar so OOO is visible to colleagues
        return service, "primary"
    except Exception:
        return None, None


def _build_event_body(doc) -> dict:
    """
    Build a Google Calendar event dict for a Leave Application.
    Creates an all-day 'Out of Office' event spanning the leave dates.
    """
    leave_type_name = frappe.db.get_value("Leave Type", doc.leave_type, "leave_type_name") or doc.leave_type
    employee_name = doc.employee_name or frappe.db.get_value("Employee", doc.employee, "employee_name")

    summary = "OOO: {} - {}".format(employee_name, leave_type_name)

    from_date = getdate(doc.from_date)
    to_date = getdate(doc.to_date)
    timezone = frappe.get_system_settings("time_zone") or "UTC"

    # Google Calendar uses exclusive end dates; OOO events can't have descriptions.
    return {
        "summary": summary,
        "start": {
            "dateTime": "{}T00:00:00".format(from_date),
            "timeZone": timezone,
        },
        "end": {
            "dateTime": "{}T00:00:00".format(add_days(to_date, 1)),
            "timeZone": timezone,
        },
        "eventType": "outOfOffice",
        "transparency": "opaque",
        "reminders": {"useDefault": False, "overrides": []},
    }


@frappe.whitelist()
def get_sync_readiness():
    """
    Report which active employees can actually sync leaves to Google Calendar.

    A leave silently stays unsynced when the employee has no Google Calendar
    record, or has one that was never authorized (no refresh token). This makes
    that state visible instead of leaving it to be discovered by a missing event.

    Call via: bench --site <site> execute
        hrms.hr.doctype.leave_application.leave_calendar_sync.get_sync_readiness
    """
    frappe.only_for(("HR Manager", "System Manager"))

    rows = []
    for emp in frappe.get_all(
        "Employee",
        filters={"status": "Active"},
        fields=["name", "employee_name", "user_id"],
        order_by="employee_name",
    ):
        if not emp.user_id:
            rows.append({**emp, "status": "No linked User account"})
            continue

        gcal = frappe.db.exists(
            "Google Calendar",
            {"user": emp.user_id, "enable": 1, "push_to_google_calendar": 1},
        )
        if not gcal:
            rows.append({**emp, "status": "No enabled Google Calendar record"})
            continue

        has_token = frappe.get_doc("Google Calendar", gcal).get_password(
            fieldname="refresh_token", raise_exception=False
        )
        rows.append(
            {
                **emp,
                "google_calendar": gcal,
                "status": "Ready" if has_token else "Not authorized — click Authorize",
            }
        )

    return rows


def ensure_custom_fields():
    """
    Create the custom fields this module depends on, if they are missing.

    Production re-clones upstream hrms on every deploy, so hrms/patches never
    runs there. Calling this from the deploy script keeps a rebuilt site working.
    Idempotent — create_custom_field skips fields that already exist.
    """
    from frappe.custom.doctype.custom_field.custom_field import create_custom_field

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
    frappe.db.commit()


def sync_pending_leaves():
    """
    Safety net: sync any approved leave that never made it to Google Calendar.

    Runs hourly via scheduler_events. Covers leaves that were missed because the
    hook did not fire (e.g. code not deployed at submit time) or because the
    Google API call failed transiently. Limited to leaves that have not ended
    yet — past leaves are no longer useful on a calendar, and skipping them
    keeps this from retrying rows that can never succeed.
    """
    if not _is_sync_enabled():
        return

    pending = frappe.get_all(
        "Leave Application",
        filters={
            "docstatus": 1,
            "status": "Approved",
            "google_calendar_synced": 0,
            "to_date": (">=", today()),
        },
        pluck="name",
    )

    frappe.flags.in_leave_calendar_sweep = True
    try:
        for name in pending:
            doc = frappe.get_doc("Leave Application", name)
            sync_leave_to_google_calendar(doc)
            frappe.db.commit()
    finally:
        frappe.flags.in_leave_calendar_sweep = False


@frappe.whitelist()
def resync_employee_leaves(employee: str):
    """
    Utility to re-sync all approved leaves for an employee.
    Useful after changing calendar settings or fixing sync issues.
    Call via: bench execute hrms.hr.doctype.leave_application.leave_calendar_sync.resync_employee_leaves --kwargs "{'employee': 'HR-EMP-00002'}"
    """
    frappe.has_permission("Leave Application", "read", throw=True)

    leaves = frappe.get_all(
        "Leave Application",
        filters={"employee": employee, "status": "Approved", "docstatus": 1},
        pluck="name",
    )

    for name in leaves:
        doc = frappe.get_doc("Leave Application", name)
        # Clear old event so it creates a fresh one on primary calendar
        frappe.db.set_value("Leave Application", name, "google_calendar_event_id", None)
        frappe.db.set_value("Leave Application", name, "google_calendar_synced", 0)
        doc.reload()
        sync_leave_to_google_calendar(doc)
        frappe.db.commit()

    return f"Re-synced {len(leaves)} approved leaves for {employee}"
