# Cancelled Document Email Print — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow email send on cancelled docs by skipping print-format attachments; keep email UX clear in the composer.

**Architecture:** Override `Email Queue` to strip cancelled print attachments on validate/send, and patch `SendMailContext.include_attachments` as a send-time safety net. Extend Desk Communication Composer via `hrms.bundle.js` to disable attach-print when `docstatus === 2`.

**Tech Stack:** Frappe/ERPNext v15, HRMS Python overrides, Desk JS bundle.

### Task 1: Backend strip + Email Queue override

**Files:**
- Create: `hrms/overrides/email_queue.py`
- Modify: `hrms/hooks.py` (`override_doctype_class`)

**Steps:**
1. Add helpers to detect/filter `print_format_attachment` when linked doc is cancelled.
2. Subclass `EmailQueue`; call strip in `validate` and `send`.
3. Patch `SendMailContext.include_attachments` at import to filter before attach.
4. Register override in `hooks.py`.

### Task 2: Frontend composer UX

**Files:**
- Create: `hrms/public/js/utils/communication_composer.js`
- Modify: `hrms/public/js/hrms.bundle.js`

**Steps:**
1. Extend `frappe.views.CommunicationComposer` to disable attach-print for cancelled forms.
2. Import from `hrms.bundle.js`.

### Task 3: Unit test for filter helper

**Files:**
- Create: `hrms/overrides/test_email_queue.py`

**Steps:**
1. Test filter keeps non-print attachments and submitted print attachments; drops cancelled print attachments.
