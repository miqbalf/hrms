"""
Google Calendar sync for Leave Applications.

When a leave is approved, this module syncs it to the employee's Google Calendar
so their Out-of-Office status is visible to colleagues.
"""

import frappe
from frappe import _
from frappe.utils import getdate, add_days, format_date
from frappe.utils.password import get_decrypted_password

GOOGLE_CALENDAR_SCOPES = [
    "https://www.googleapis.com/auth/calendar.events",
    "https://www.googleapis.com/auth/calendar",
]


def sync_leave_to_google_calendar(doc, method=None):
    """
    Sync an approved Leave Application to the employee's Google Calendar.
    Called via doc_events on_submit (only when status == "Approved").
    """
    if not _is_sync_enabled():
        return

    if doc.status != "Approved":
        return

    if doc.docstatus != 1:
        return

    try:
        service = _get_google_calendar_service(doc)
        if not service:
            frappe.log_error(
                title="Leave Calendar Sync: No Google Calendar service",
                message=f"Could not get Google Calendar service for leave {doc.name}, employee {doc.employee}",
            )
            return

        event = _build_event_body(doc)

        if doc.get("google_calendar_event_id"):
            # Update existing event
            service.events().update(
                calendarId="primary",
                eventId=doc.google_calendar_event_id,
                body=event,
            ).execute()
            frappe.msgprint(
                _("Google Calendar event updated for {0}").format(doc.employee_name),
                alert=True,
            )
        else:
            # Create new event
            created = service.events().insert(
                calendarId="primary",
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
            message=f"Failed to sync leave {doc.name}: {str(e)}",
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
        # Wasn't synced before — maybe it was approved via an update
        sync_leave_to_google_calendar(doc)
        return

    try:
        service = _get_google_calendar_service(doc)
        if not service:
            return

        event = _build_event_body(doc)
        service.events().update(
            calendarId="primary",
            eventId=doc.google_calendar_event_id,
            body=event,
        ).execute()

    except Exception as e:
        frappe.log_error(
            title="Leave Calendar Sync Update Error",
            message=f"Failed to update Google Calendar event for leave {doc.name}: {str(e)}",
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
        service = _get_google_calendar_service(doc)
        if not service:
            return

        service.events().delete(
            calendarId="primary",
            eventId=event_id,
        ).execute()

        doc.db_set("google_calendar_event_id", None, update_modified=False)
        doc.db_set("google_calendar_synced", 0, update_modified=False)

    except Exception as e:
        # Event might already be deleted — that's OK
        if "Resource has been deleted" in str(e) or "404" in str(e):
            doc.db_set("google_calendar_event_id", None, update_modified=False)
            doc.db_set("google_calendar_synced", 0, update_modified=False)
        else:
            frappe.log_error(
                title="Leave Calendar Sync Delete Error",
                message=f"Failed to delete Google Calendar event for leave {doc.name}: {str(e)}",
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
    user_id = frappe.db.get_value("Employee", employee_name, "user_id")
    return user_id


def _get_google_calendar_service(doc):
    """
    Build a Google Calendar API service for the leave applicant's Google account.
    Returns None if the user hasn't authorized Google Calendar access.
    """
    from googleapiclient.discovery import build
    from google.oauth2.credentials import Credentials

    employee_user = _get_employee_user_id(doc.employee)
    if not employee_user:
        return None

    credentials = _get_user_google_credentials(employee_user)
    if not credentials:
        return None

    try:
        service = build("calendar", "v3", credentials=credentials)
        return service
    except Exception:
        return None


def _get_user_google_credentials(user_id: str):
    """
    Retrieve valid Google OAuth credentials for a user.
    Uses the OAuth Bearer Token stored when the user logged in via Google.
    """
    from google.oauth2.credentials import Credentials
    from google.auth.transport.requests import Request

    # Find the Google OAuth token for this user
    token_record = frappe.db.get_value(
        "OAuth Bearer Token",
        {"user": user_id, "provider": "google"},
        ["access_token", "refresh_token", "expires_at", "scopes"],
        as_dict=True,
    )

    if not token_record:
        # Try to find any Google token for this user
        token_record = frappe.db.get_value(
            "OAuth Bearer Token",
            {"user": user_id},
            ["access_token", "refresh_token", "expires_at", "scopes", "provider"],
            as_dict=True,
        )
        if not token_record or "google" not in (token_record.get("provider") or "").lower():
            frappe.msgprint(
                _("Employee {0} has not logged in with Google. Please login with Google first.").format(
                    user_id
                ),
                alert=True,
            )
            return None

    # Get client config from Social Login Key
    google_provider = frappe.db.get_value(
        "Social Login Key",
        {"provider_name": "Google", "enable_social_login": 1},
        ["client_id", "client_secret", "name"],
        as_dict=True,
    )

    if not google_provider:
        # Try case-insensitive
        google_providers = frappe.get_all(
            "Social Login Key",
            filters={"enable_social_login": 1},
            fields=["client_id", "client_secret", "name", "provider_name"],
        )
        google_provider = next(
            (p for p in google_providers if "google" in (p.get("provider_name") or "").lower()),
            None,
        )

    if not google_provider:
        frappe.msgprint(
            _("Google OAuth is not configured. Please set up Google Social Login Key."),
            alert=True,
        )
        return None

    client_id = google_provider.client_id
    client_secret = get_decrypted_password(
        "Social Login Key", google_provider.name, "client_secret"
    )

    if not client_id or not client_secret:
        return None

    # Check if token has calendar scopes
    token_scopes = (token_record.get("scopes") or "").split()
    has_calendar_scope = any(
        "calendar" in s for s in token_scopes
    )

    credentials = Credentials(
        token=token_record.access_token,
        refresh_token=token_record.refresh_token,
        token_uri="https://oauth2.googleapis.com/token",
        client_id=client_id,
        client_secret=client_secret,
        scopes=GOOGLE_CALENDAR_SCOPES if not has_calendar_scope else token_scopes,
    )

    # Refresh if expired
    if credentials.expired and credentials.refresh_token:
        try:
            credentials.refresh(Request())
            # Store the new access token
            frappe.db.set_value(
                "OAuth Bearer Token",
                {"user": user_id, "provider": token_record.get("provider")},
                "access_token",
                credentials.token,
            )
        except Exception as e:
            frappe.log_error(
                title="Google Calendar Token Refresh Error",
                message=f"Failed to refresh token for user {user_id}: {str(e)}",
            )
            return None

    return credentials


def _build_event_body(doc) -> dict:
    """
    Build a Google Calendar event dict for a Leave Application.
    Creates an 'Out of Office' event spanning the leave dates.
    """
    leave_type_name = frappe.db.get_value("Leave Type", doc.leave_type, "leave_type_name") or doc.leave_type
    employee_name = doc.employee_name or frappe.db.get_value("Employee", doc.employee, "employee_name")

    summary = _("OOO: {0} - {1}").format(employee_name, leave_type_name)

    description = f"{doc.leave_type}"
    if doc.description:
        description += f"\n\n{doc.description}"

    # For all-day events, Google Calendar uses the date field (not dateTime)
    # The end date should be exclusive (the day after the last day)
    from_date = getdate(doc.from_date)
    to_date = getdate(doc.to_date)

    if doc.half_day and doc.half_day_date:
        # For half day, create a timed event on the half-day date
        half_day_date = getdate(doc.half_day_date)
        if from_date == to_date:
            # Single half-day
            return {
                "summary": summary,
                "description": description,
                "start": {
                    "date": str(from_date),
                },
                "end": {
                    "date": str(add_days(from_date, 1)),
                },
                "transparency": "opaque",
                "reminders": {
                    "useDefault": False,
                    "overrides": [],
                },
            }

    # All-day event spanning from_date to to_date (inclusive)
    return {
        "summary": summary,
        "description": description,
        "start": {
            "date": str(from_date),
        },
        "end": {
            "date": str(add_days(to_date, 1)),  # Google Calendar end is exclusive
        },
        "transparency": "opaque",
        "reminders": {
            "useDefault": False,
            "overrides": [],
        },
    }
