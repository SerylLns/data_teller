module DataTeller
  # ADR 0002: the palette is a web component; these settings only choose how it is mounted.
  class UiConfiguration
    MODES = %i[modal inline].freeze
    THEMES = %i[system light dark].freeze

    attr_reader :mode, :theme, :keyboard_shortcut

    def initialize
      @mode = :modal
      @theme = :system
      @keyboard_shortcut = "mod+k"
    end

    def mode=(value)
      @mode = ensure_in!(:mode, value, MODES)
    end

    def theme=(value)
      @theme = ensure_in!(:theme, value, THEMES)
    end

    # nil disables the shortcut: Ctrl+K collides with browser search focus and with palettes the host may already have.
    def keyboard_shortcut=(value)
      unless value.nil? || (value.is_a?(String) && !value.strip.empty?)
        raise ConfigurationError, "ui.keyboard_shortcut must be a non-empty String or nil, got #{value.inspect}"
      end

      @keyboard_shortcut = value
    end

    private

    def ensure_in!(name, value, allowed)
      return value if allowed.include?(value)

      raise ConfigurationError, "ui.#{name} must be one of #{allowed.inspect}, got #{value.inspect}"
    end
  end
end
