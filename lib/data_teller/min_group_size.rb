module DataTeller
  # `min_group_size 5, of: :customer, except: %i[admin]` (ADR 0012): a group with fewer than `minimum` distinct `of` is left out, for every
  # role that reads the dataset except the ones named. `of` is nil to count the dataset's own rows, or a direct belongs_to whose key is counted.
  class MinGroupSize < Data.define(:minimum, :of, :except)
    def initialize(minimum:, of: nil, except: [])
      # 1 would only hide empty groups: a threshold that protects no one but reads as if it did.
      unless minimum.is_a?(Integer) && minimum >= 2
        raise DeclarationError, "min_group_size must be an Integer of at least 2, got #{minimum.inspect}"
      end

      super(
        minimum: minimum,
        of: of.nil? ? nil : NameFormat.ensure!(of, "min_group_size of:"),
        except: Array(except).empty? ? [].freeze : NameFormat.roles(except, "min_group_size except:")
      )
    end

    # Exempt only if named: a role added later is held to the threshold until someone decides otherwise (ADR 0012 D2). One exempt role is
    # enough: the catalog of a user is what their roles see together, so an admin who is also support sees the rows as admin.
    def applies_to?(roles) = (roles & except).empty?
  end
end
