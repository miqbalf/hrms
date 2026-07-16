# Cancelled Document Email Print Attach — Design

**Date:** 2026-07-16  
**Status:** Approved

## Problem

Sending email from a cancelled document with “Attach Document Print” fails in Email Queue:

`PermissionError: Not allowed to print cancelled documents`

SMTP and Docker were fine; Frappe blocks print of `docstatus == 2`.

## Goal

- Cancelled documents can still send email.
- Print PDF is not attached for cancelled docs.
- Draft/submitted docs keep current attach-print behavior.

## Approach

1. **Backend:** Strip cancelled print-format attachments from Email Queue before/at send so queue send succeeds.
2. **Frontend:** In Communication Composer, when the open form is cancelled, uncheck and disable “Attach Document Print” with a short explanation.

## Scope

- All doctypes (same Frappe rule).
- Out of scope: wkhtmltopdf/`pdfkit` failures on non-cancelled docs.

## Acceptance

- Email from a cancelled Expense Claim (or any cancelled doc) sends without print attachment.
- Email from submitted docs with attach print still attempts print as before.
- Existing Error queue rows for cancelled print can be retried successfully after deploy.
