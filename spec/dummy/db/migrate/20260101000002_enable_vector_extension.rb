class EnableVectorExtension < ActiveRecord::Migration[7.2]
  def change
    # Needed from the retrieval milestone (embeddings); enabled early so CI and dev fail fast if missing.
    enable_extension "vector"
    # Used later for fuzzy value matching and French-insensitive search.
    enable_extension "pg_trgm"
    enable_extension "unaccent"
  end
end
