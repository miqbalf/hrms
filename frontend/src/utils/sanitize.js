import DOMPurify from "dompurify"

export function sanitizeHTML(html) {
	if (!html) return ""
	return DOMPurify.sanitize(String(html), {
		USE_PROFILES: { html: true },
		FORBID_TAGS: ["style", "form", "input", "button", "iframe", "object", "embed"],
		FORBID_ATTR: ["style"],
	})
}
