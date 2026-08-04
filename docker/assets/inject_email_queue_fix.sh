#!/bin/bash
# Usage: inject_email_queue_fix.sh [ASSETS_DIR]
# ASSETS_DIR defaults to the custom-assets bind mount. The deploy passes the
# fork's docker/assets instead, because Coolify does not sync the bind mount
# from git — see DEPLOY_FIXES.md #13.
set -e
SRC="${1:-/home/frappe/custom-assets}"
mkdir -p apps/hrms/hrms/overrides apps/hrms/hrms/public/js/utils
if [ -f "$SRC/email_queue.py" ]; then
  cp "$SRC/email_queue.py" apps/hrms/hrms/overrides/email_queue.py
fi
if [ -f "$SRC/communication_composer.js" ]; then
  cp "$SRC/communication_composer.js" apps/hrms/hrms/public/js/utils/communication_composer.js
fi
if [ -f apps/hrms/hrms/overrides/email_queue.py ] && ! grep -q '"Email Queue"' apps/hrms/hrms/hooks.py; then
  python3 - <<'PY'
from pathlib import Path
path = Path("apps/hrms/hrms/hooks.py")
text = path.read_text()
needle = '"Project": "hrms.overrides.employee_project.EmployeeProject",'
addition = needle + '\n\t"Email Queue": "hrms.overrides.email_queue.EmailQueue",'
if needle in text and '"Email Queue"' not in text:
    path.write_text(text.replace(needle, addition, 1))
PY
fi
if [ -f apps/hrms/hrms/public/js/utils/communication_composer.js ] && ! grep -q 'communication_composer' apps/hrms/hrms/public/js/hrms.bundle.js; then
  python3 - <<'PY'
from pathlib import Path
path = Path("apps/hrms/hrms/public/js/hrms.bundle.js")
text = path.read_text()
line = 'import "./utils/communication_composer";\n'
if line not in text:
    path.write_text(text.replace('import "./utils/leave_utils";\n', 'import "./utils/leave_utils";\n' + line))
PY
fi
echo "Cancelled-doc email print fix injected."
