module DataTeller
  # `list default: %i[ordered_at customer.city status]` (ADR 0016 D2): the dataset can be listed row by row, and these are the columns of a
  # list whose query names none. The names are dimensions, own or through a path; the boot checks that they exist and are not sensitive.
  class ListDeclaration < Data.define(:default)
    # A list wider than this is a table nobody reads in a palette, and each column is one more value per row shown.
    MAX_COLUMNS = 8
    PATH = /\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){0,2}\z/

    def initialize(default:)
      columns = Array(default)
      raise DeclarationError, "list: default: needs at least one dimension, e.g. list default: %i[created_at status]" if columns.empty?
      if columns.size > MAX_COLUMNS
        raise DeclarationError, "list: default: has #{columns.size} columns, at most #{MAX_COLUMNS}"
      end

      names = columns.map do |column|
        unless (column.is_a?(Symbol) || column.is_a?(String)) && PATH.match?(column.to_s)
          raise DeclarationError, "list: default: #{column.inspect} is not a dimension name such as :status or :\"customer.city\""
        end

        column.to_sym
      end
      raise DeclarationError, "list: default: names a column twice" if names.uniq.size < names.size

      super(default: names.freeze)
    end
  end
end
