"""
Diagnostic script for Google Calendar sync.
Run this in bench console to check what's wrong:

    bench --site hrms.localhost console
    exec(open("diagnose_calendar_sync.py").read())
"""

import frappe

USER_EMAIL = "ary.dewi@treeo.one"

print("=" * 60)
print(f"🔍 Diagnosing Google Calendar sync for: {USER_EMAIL}")
print("=" * 60)

# 1. Find the user
user = frappe.db.get_value("User", {"email": USER_EMAIL}, ["name", "email", "enabled"], as_dict=True)
if not user:
    print(f"❌ User not found: {USER_EMAIL}")
    exit()
print(f"\n✅ User found: {user.name} (enabled={user.enabled})")

# 2. Find the employee
employee = frappe.db.get_value("Employee", {"user_id": user.name},
    ["name", "employee_name", "status"], as_dict=True)
if employee:
    print(f"✅ Employee found: {employee.name} ({employee.employee_name}, status={employee.status})")
else:
    print(f"⚠️  No Employee linked to this user — leave sync won't work for non-employees")

# 3. Check custom fields exist
for field in ["google_calendar_event_id", "google_calendar_synced"]:
    exists = frappe.db.exists("Custom Field", {"dt": "Leave Application", "fieldname": field})
    print(f"{'✅' if exists else '❌'} Custom field 'Leave Application.{field}': {'exists' if exists else 'MISSING — run bench migrate!'}")

# 4. Check HR Settings toggle
sync_enabled = frappe.db.get_single_value("HR Settings", "enable_google_calendar_sync")
print(f"{'✅' if sync_enabled else '❌'} HR Settings.enable_google_calendar_sync: {sync_enabled}")

# 5. Check Google Social Login Key config
google_provider = frappe.db.get_value(
    "Social Login Key",
    {"provider_name": "Google", "enable_social_login": 1},
    ["name", "provider_name", "client_id", "scopes", "base_url"],
    as_dict=True,
)
if not google_provider:
    # Try case-insensitive
    providers = frappe.get_all("Social Login Key",
        filters={"enable_social_login": 1},
        fields=["name", "provider_name", "client_id", "scopes"])
    google_provider = next((p for p in providers if "google" in (p.provider_name or "").lower()), None)

if google_provider:
    print(f"✅ Google Social Login found: {google_provider.name}")
    print(f"   client_id: {'SET' if google_provider.client_id else 'MISSING'}")
    print(f"   scopes: {google_provider.scopes}")
    has_calendar = "calendar" in (google_provider.scopes or "").lower()
    print(f"   {'✅' if has_calendar else '❌'} Calendar scopes included: {has_calendar}")
else:
    print("❌ No Google Social Login Key found!")

# 6. Check OAuth Bearer Token for this user
tokens = frappe.get_all("OAuth Bearer Token",
    filters={"user": user.name},
    fields=["name", "provider", "scopes", "expires_at", "creation"],
    order_by="creation desc")
if tokens:
    for t in tokens:
        print(f"✅ OAuth Bearer Token: {t.name}")
        print(f"   provider: {t.provider}")
        print(f"   scopes: {t.scopes}")
        print(f"   expires_at: {t.expires_at}")
        print(f"   has_calendar_scope: {'calendar' in (t.scopes or '').lower()}")
else:
    print("❌ No OAuth Bearer Token found for this user!")
    print("   → This is the likely problem: Google login doesn't persist API tokens.")
    print("   → Each user must authorize Calendar access separately.")

# 7. Check User Social Login
social = frappe.get_all("User Social Login",
    filters={"user": user.name},
    fields=["name", "provider", "uid"])
if social:
    for s in social:
        print(f"✅ User Social Login: {s.name} (provider={s.provider})")
else:
    print("⚠️  No User Social Login — user hasn't logged in with Google?")

# 8. Check recent error logs
logs = frappe.get_all("Error Log",
    filters={"title": ["like", "%Calendar Sync%"]},
    fields=["name", "title", "error", "creation"],
    order_by="creation desc",
    limit=5)
if logs:
    print(f"\n📋 Recent Calendar Sync errors:")
    for l in logs:
        print(f"   [{l.creation}] {l.title}: {l.error[:200]}")
else:
    print("\n📋 No Calendar Sync errors logged")

# 9. Check approved leave applications for this employee
if employee:
    leaves = frappe.get_all("Leave Application",
        filters={"employee": employee.name, "status": "Approved", "docstatus": 1},
        fields=["name", "leave_type", "from_date", "to_date", "google_calendar_event_id", "google_calendar_synced"],
        order_by="creation desc",
        limit=3)
    print(f"\n📋 Recent approved leaves: {len(leaves)} found")
    for l in leaves:
        print(f"   {l.name}: {l.leave_type} ({l.from_date} → {l.to_date})")
        print(f"   synced={l.google_calendar_synced}, event_id={'SET' if l.google_calendar_event_id else 'MISSING'}")

print("\n" + "=" * 60)
print("Diagnostic complete. Check the ❌ items above.")
print("=" * 60)
