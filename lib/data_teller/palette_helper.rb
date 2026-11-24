module DataTeller
  # In the host's views: <%= data_teller_palette %> (ADR 0010 D1). Renders nothing for someone the endpoint would refuse, or when the
  # engine is off, so that a page never shows a palette that cannot answer. The endpoint checks again: this is a courtesy, not a guard.
  module PaletteHelper
    def data_teller_palette(mode: nil)
      return unless DataTeller.enabled?

      user = DataTeller.config.current_user_for(request)
      return unless user && Catalog.for_user(user).datasets.any?

      # The labels in the language of the answers. Without a c.locale, the page's own.
      I18n.with_locale(DataTeller.config.locale_for(user)) do
        safe_join([ data_teller_assets, data_teller_element(mode || DataTeller.config.ui.mode) ])
      end
    end

    private

    # No inline script or style, for hosts with a Content Security Policy; the nonce is for those that demand one on every tag.
    def data_teller_assets
      paths = Engine.routes.url_helpers
      nonce = respond_to?(:content_security_policy_nonce) ? content_security_policy_nonce : nil
      version = { v: DataTeller::VERSION }
      safe_join([
        tag.link(rel: "stylesheet", href: paths.palette_style_path(version), nonce: nonce),
        tag.script(src: paths.palette_script_path(version), defer: true, nonce: nonce)
      ])
    end

    def data_teller_element(mode)
      ui = DataTeller.config.ui
      content_tag("data-teller-palette", nil, data: {
        mode: mode, theme: ui.theme, shortcut: ui.keyboard_shortcut,
        endpoint: Engine.routes.url_helpers.ask_path, rows_endpoint: Engine.routes.url_helpers.rows_path, csrf_token: form_authenticity_token,
        trigger: t("data_teller.palette.trigger"), placeholder: t("data_teller.palette.placeholder"),
        submit: t("data_teller.palette.submit"), error: t("data_teller.palette.error")
      })
    end
  end
end
