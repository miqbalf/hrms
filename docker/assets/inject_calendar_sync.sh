#!/bin/bash
# Inject Google Calendar sync for Leave Applications into the freshly cloned
# upstream hrms app. Production does `rm -rf apps/hrms` + `bench get-app` on
# every deploy, so this customization has to be re-applied each time.
#
# Usage: inject_calendar_sync.sh [FORK_ROOT]
#   FORK_ROOT  A checkout of the TREEO hrms fork. When given, the module is
#              taken from its real source path, so the fork is the single
#              source of truth. Without it, we fall back to the copy sitting
#              next to this script (the custom-assets bind mount), which
#              Coolify does not sync from git — see DEPLOY_FIXES.md #13.
#
# Run from the bench directory (/home/frappe/frappe-bench).
set -e

FORK_ROOT="${1:-}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_REL="hrms/hr/doctype/leave_application/leave_calendar_sync.py"
TARGET_DIR="apps/hrms/hrms/hr/doctype/leave_application"

if [ -n "$FORK_ROOT" ] && [ -f "$FORK_ROOT/$MODULE_REL" ]; then
  SOURCE="$FORK_ROOT/$MODULE_REL"
elif [ -f "$SELF_DIR/leave_calendar_sync.py" ]; then
  SOURCE="$SELF_DIR/leave_calendar_sync.py"
else
  echo "WARNING: leave_calendar_sync.py not found."
  echo "WARNING: looked in '$FORK_ROOT/$MODULE_REL' and '$SELF_DIR/'."
  echo "WARNING: approved leaves will NOT sync to Google Calendar until this is fixed."
  exit 0
fi

if [ ! -d "$TARGET_DIR" ]; then
  echo "WARNING: $TARGET_DIR missing — is the hrms app cloned yet? Skipping calendar sync."
  exit 0
fi

cp "$SOURCE" "$TARGET_DIR/leave_calendar_sync.py"
python3 -m py_compile "$TARGET_DIR/leave_calendar_sync.py"
echo "Calendar sync module installed from $SOURCE"

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

# Fail loudly in the deploy log if the hooks did not actually take effect —
# a silently missing hook is exactly how this feature disappeared before.
if grep -q "leave_calendar_sync" apps/hrms/hrms/hooks.py; then
  echo "Leave Application Google Calendar sync injected."
else
  echo "WARNING: failed to register calendar sync hooks in hooks.py!"
fi
