frappe.provide("hrms");

(() => {
	const OriginalComposer = frappe.views.CommunicationComposer;
	if (!OriginalComposer || OriginalComposer.__hrms_cancelled_print_patched) {
		return;
	}

	frappe.views.CommunicationComposer = class CommunicationComposer extends OriginalComposer {
		setup_print() {
			super.setup_print();
			this.disable_attach_print_for_cancelled();
		}

		setup_email() {
			if (this.is_cancelled_doc()) {
				this.attach_document_print = 0;
			}
			super.setup_email();
			this.disable_attach_print_for_cancelled();
		}

		is_cancelled_doc() {
			return cint(this.frm?.doc?.docstatus) === 2;
		}

		disable_attach_print_for_cancelled() {
			if (!this.is_cancelled_doc()) {
				return;
			}

			const fields = this.dialog?.fields_dict;
			if (!fields?.attach_document_print) {
				return;
			}

			fields.attach_document_print.set_value(0);
			fields.attach_document_print.df.read_only = 1;
			fields.attach_document_print.df.description = __(
				"Print cannot be attached for cancelled documents. You can still send the email."
			);
			fields.attach_document_print.refresh();
			if (fields.select_print_format) {
				$(fields.select_print_format.wrapper).toggle(false);
			}
		}
	};

	frappe.views.CommunicationComposer.__hrms_cancelled_print_patched = true;
})();
