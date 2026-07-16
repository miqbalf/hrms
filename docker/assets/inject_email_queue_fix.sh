#!/bin/bash
set -e
mkdir -p apps/hrms/hrms/overrides apps/hrms/hrms/public/js/utils
if [ -f /home/frappe/custom-assets/email_queue.py ]; then
  cp /home/frappe/custom-assets/email_queue.py apps/hrms/hrms/overrides/email_queue.py
fi
if [ -f /home/frappe/custom-assets/communication_composer.js ]; then
  cp /home/frappe/custom-assets/communication_composer.js apps/hrms/hrms/public/js/utils/communication_composer.js
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
