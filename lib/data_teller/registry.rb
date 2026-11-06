require "digest"
require "json"

module DataTeller
  # Everything the DSL declared. Frozen after boot validation: no runtime mutation, safe across threads.
  class Registry
    def initialize
      @datasets = {}
      @frozen = false
    end

    def register(dataset)
      raise DeclarationError, "registry is frozen, cannot declare #{dataset.name.inspect}" if frozen?
      raise DeclarationError, "dataset #{dataset.name.inspect} is declared twice" if @datasets.key?(dataset.name)

      @datasets[dataset.name] = dataset
    end

    def dataset(name)
      @datasets[name.to_sym]
    end

    def datasets
      @datasets.values.freeze
    end

    def frozen?
      @frozen
    end

    def freeze!
      @datasets.freeze
      @frozen = true
      self
    end

    # Fingerprint of the declarations; part of the cache key of schemas and catalogs (ADR 0004 D5).
    def version
      raise DeclarationError, "registry must be frozen before it has a version" unless frozen?

      @version ||= Digest::SHA256.hexdigest(JSON.generate(@datasets.sort.map { |_, dataset| dataset.to_h })).first(16)
    end
  end
end
