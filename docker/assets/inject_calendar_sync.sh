#!/bin/bash
# Inject Google Calendar sync for Leave Applications into the freshly cloned
# upstream hrms app. Production does `rm -rf apps/hrms` + `bench get-app` on
# every deploy, so this customization has to be re-applied each time.
set -e
TARGET_DIR=apps/hrms/hrms/hr/doctype/leave_application
if [ ! -f /home/frappe/custom-assets/leave_calendar_sync.py ]; then
  echo "leave_calendar_sync.py not found in custom-assets — skipping calendar sync injection."
  exit 0
fi
cp /home/frappe/custom-assets/leave_calendar_sync.py "$TARGET_DIR/leave_calendar_sync.py"

# Register the doc_events and the hourly safety-net sweep. Appended at the end
# of hooks.py so we never have to match upstream's dict formatting.
if ! grep -q "leave_calendar_sync" apps/hrms/hrms/hooks.py; then
  cat >> apps/hrms/hrms/hooks.py <<'PY'

# TREEO: Google Calendar sync for approved Leave Applications
_leave_calendar_sync = "hrms.hr.doctype.leave_application.leave_calendar_sync"
doc_events.setdefault("Leave Application", {}).update(
	{
		"on_submit": f"{_leave_calendar_sync}.sync_leave_to_google_calendar",
		"on_update_after_submit": f"{_leave_calendar_sync}.update_google_calendar_event",
		"on_cancel": f"{_leave_calendar_sync}.delete_google_calendar_event",
		"on_trash": f"{_leave_calendar_sync}.delete_google_calendar_event",
	}
)
scheduler_events.setdefault("hourly", []).append(f"{_leave_calendar_sync}.sync_pending_leaves")
PY
fi
echo "Leave Application Google Calendar sync injected."
