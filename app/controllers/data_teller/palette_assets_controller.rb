module DataTeller
  # The palette's JS and CSS: public files, the same for everyone.
  class PaletteAssetsController < ApplicationController
    # Rails refuses a cross-origin GET that answers JavaScript, and a <script src> is not an XHR, so it would refuse its own page.
    # This file holds no data, so there is nothing for another site to read.
    skip_forgery_protection

    DIRECTORY = File.expand_path("../../../lib/data_teller/palette", __dir__)

    def script = serve("palette.js", "text/javascript")
    def style = serve("palette.css", "text/css")

    private

    def serve(file, content_type)
      expires_in 1.hour, public: true
      send_file File.join(DIRECTORY, file), type: content_type, disposition: "inline"
    end
  end
end
