"""
Google Calendar sync for Leave Applications (Frappe v15).

Uses Frappe's built-in Google Calendar integration for OAuth.
Each employee must have a "Google Calendar" record with Calendar access authorized.
"""

import frappe
from frappe import _
from frappe.utils import getdate, add_days


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
        frappe.msgprint(
            _("Synced to Google Calendar for {0}").format(doc.employee_name),
            alert=True,
        )

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
        frappe.msgprint(
            _("Employee {0} has no linked User account. Cannot sync to Google Calendar.").format(
                doc.employee
            ),
            alert=True,
        )
        return None, None

    # Find the employee's Google Calendar record
    gcal_name = frappe.db.exists(
        "Google Calendar",
        {"user": employee_user, "enable": 1, "push_to_google_calendar": 1},
    )
    if not gcal_name:
        frappe.msgprint(
            _("Employee {0} has not set up Google Calendar sync. "
              "Please create a Google Calendar record in Desk and authorize it.").format(
                doc.employee_name or doc.employee
            ),
            alert=True,
        )
        return None, None

    try:
        google_calendar_doc = frappe.get_doc("Google Calendar", gcal_name)
    except frappe.DoesNotExistError:
        return None, None

    if not google_calendar_doc.refresh_token:
        frappe.msgprint(
            _("Google Calendar for {0} is not authorized. Please click 'Authorize' on the Google Calendar record.").format(
                doc.employee_name or doc.employee
            ),
            alert=True,
        )
        return None, None

    google_settings = frappe.get_cached_doc("Google Settings")
    if not google_settings.enable or not google_settings.client_id:
        frappe.msgprint(
            _("Google Settings are not configured. Please set up Google API in Google Settings."),
            alert=True,
        )
        return None, None

    try:
        access_token = google_calendar_doc.get_access_token()
    except Exception as e:
        frappe.msgprint(
            _("Could not get Google Calendar access for {0}: {1}").format(
                doc.employee_name or doc.employee, str(e)
            ),
            alert=True,
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
        return service, google_calendar_doc.google_calendar_id or "primary"
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

    description = doc.leave_type
    if doc.description:
        description += "\n\n{}".format(doc.description)

    from_date = getdate(doc.from_date)
    to_date = getdate(doc.to_date)

    # Google Calendar uses exclusive end dates for all-day events
    return {
        "summary": summary,
        "description": description,
        "start": {"date": str(from_date)},
        "end": {"date": str(add_days(to_date, 1))},
        "transparency": "opaque",
        "reminders": {"useDefault": False, "overrides": []},
    }
