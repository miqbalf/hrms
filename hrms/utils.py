import frappe

__version__ = "17.0.0-dev"


def refetch_resource(cache_key: str | list, user=None):
    frappe.publish_realtime(
        "hrms:refetch_resource",
        {"cache_key": cache_key},
        user=user or frappe.session.user,
        after_commit=True,
    )


def apply_branding():
    """Apply TREEO branding to all relevant DocTypes."""
    frappe.db.set_single_value("Website Settings", "brand_html",
        '<span class="brand-label">TREEO HR system</span>')
    frappe.db.set_single_value("Website Settings", "tagline", "TREEO HR system")
    frappe.db.set_single_value("Website Settings", "app_logo", "/files/treeo_logo.png")
    frappe.db.set_single_value("Website Settings", "favicon", "/files/favicon.png")
    frappe.db.set_single_value("Navbar Settings", "app_logo", "/files/treeo_logo.png")
    frappe.db.set_single_value("System Settings", "app_name", "TREEO HR system")
    frappe.db.commit()
