// <data-teller-palette>: the palette as a custom element, on the native <dialog> (ADR 0002). No framework, nothing required of the host.
// The server answers HTML fragments it has escaped; nothing here builds markup from a value.
class DataTellerPalette extends HTMLElement {
  connectedCallback() {
    if (this.form) return;

    this.build();
    this.onKeydown = (event) => this.shortcut(event);
    if (this.dataset.shortcut) document.addEventListener("keydown", this.onKeydown);
  }

  disconnectedCallback() {
    document.removeEventListener("keydown", this.onKeydown);
    this.request?.abort();
  }

  build() {
    this.input = Object.assign(document.createElement("input"), {
      type: "text", maxLength: 500, autocomplete: "off", placeholder: this.dataset.placeholder, className: "dt-input"
    });
    this.input.setAttribute("aria-label", this.dataset.placeholder);

    const submit = Object.assign(document.createElement("button"), { type: "submit", textContent: this.dataset.submit, className: "dt-submit" });
    this.form = Object.assign(document.createElement("form"), { className: "dt-form" });
    this.form.append(this.input, submit);
    this.form.addEventListener("submit", (event) => this.ask(event));

    this.output = Object.assign(document.createElement("div"), { className: "dt-output" });
    this.output.setAttribute("aria-live", "polite");
    this.output.addEventListener("click", (event) => {
      const more = event.target.closest(".dt-more");
      if (more) this.more(more);
    });

    if (this.dataset.mode === "inline") {
      this.append(this.form, this.output);
    } else {
      this.buildDialog();
    }
  }

  // The trigger stays visible: a shortcut alone can't be discovered, and doesn't exist on a phone.
  buildDialog() {
    const trigger = Object.assign(document.createElement("button"), { type: "button", textContent: this.dataset.trigger, className: "dt-trigger" });
    trigger.addEventListener("click", () => this.open());

    this.dialog = Object.assign(document.createElement("dialog"), { className: "dt-dialog" });
    this.dialog.setAttribute("aria-label", this.dataset.trigger);
    this.dialog.append(this.form, this.output);
    // A click on the backdrop lands on the dialog itself; its content has its own elements.
    this.dialog.addEventListener("click", (event) => { if (event.target === this.dialog) this.dialog.close(); });

    this.append(trigger, this.dialog);
  }

  open() {
    if (!this.dialog) return this.input.focus();

    if (!this.dialog.open) this.dialog.showModal();
    this.input.focus();
  }

  shortcut(event) {
    const [key, ...modifiers] = this.dataset.shortcut.toLowerCase().split("+").reverse();
    if (event.key.toLowerCase() !== key) return;
    if (!modifiers.every((modifier) => this.modifierHeld(event, modifier))) return;
    // While typing the key belongs to the field: Ctrl+K already means something in many of them (ADR 0002).
    if (this.typing(event.target)) return;

    event.preventDefault();
    this.open();
  }

  modifierHeld(event, modifier) {
    switch (modifier) {
      case "mod": return event.metaKey || event.ctrlKey;
      case "ctrl": return event.ctrlKey;
      case "cmd": case "meta": return event.metaKey;
      case "alt": return event.altKey;
      case "shift": return event.shiftKey;
      default: return false;
    }
  }

  typing(element) {
    return element.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(element.tagName);
  }

  async ask(event) {
    event.preventDefault();
    const question = this.input.value.trim();
    if (!question) return;

    // A new question replaces the one still running: answers can't arrive out of order.
    this.request?.abort();
    const request = this.request = new AbortController();
    this.setAttribute("aria-busy", "true");

    try {
      const response = await fetch(this.dataset.endpoint, {
        method: "POST",
        credentials: "same-origin",
        signal: request.signal,
        headers: { "X-CSRF-Token": this.dataset.csrfToken, "Content-Type": "application/x-www-form-urlencoded", Accept: "text/html" },
        body: new URLSearchParams({ data_teller_question: question })
      });
      if (!response.ok) throw new Error(`status ${response.status}`);
      this.output.innerHTML = await response.text();
    } catch (error) {
      if (error.name === "AbortError") return;
      this.output.textContent = this.dataset.error;
    }
    if (this.request === request) this.removeAttribute("aria-busy");
  }

  // A list's next page (ADR 0016 D4): the query and the cursor the server gave, sent back as they were. The rows are appended to the
  // table already shown and the footer replaced; a refusal replaces the footer with its message.
  async more(button) {
    const list = button.closest(".dt-list");
    this.request?.abort();
    const request = this.request = new AbortController();
    button.disabled = true;
    this.setAttribute("aria-busy", "true");

    try {
      const response = await fetch(this.dataset.rowsEndpoint, {
        method: "POST",
        credentials: "same-origin",
        signal: request.signal,
        headers: { "X-CSRF-Token": this.dataset.csrfToken, "Content-Type": "application/x-www-form-urlencoded", Accept: "text/html" },
        body: new URLSearchParams({
          data_teller_query: button.dataset.query, data_teller_after: button.dataset.after, data_teller_total: button.dataset.total
        })
      });
      if (!response.ok) throw new Error(`status ${response.status}`);

      const page = document.createElement("template");
      page.innerHTML = await response.text();
      const rows = page.content.querySelector("tbody");
      if (rows) list.querySelector("tbody").append(...rows.children);
      const footer = page.content.querySelector(".dt-list-footer");
      list.querySelector(".dt-list-footer").replaceWith(footer || page.content);
    } catch (error) {
      if (error.name === "AbortError") return;
      button.disabled = false;
      list.querySelector(".dt-list-footer").textContent = this.dataset.error;
    }
    if (this.request === request) this.removeAttribute("aria-busy");
  }
}

if (!customElements.get("data-teller-palette")) customElements.define("data-teller-palette", DataTellerPalette);
