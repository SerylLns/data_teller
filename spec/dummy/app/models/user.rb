# Not exposed to DataTeller: it is who asks the questions, not what they are about.
class User < ApplicationRecord
  belongs_to :account

  def roles = [ role ]
end
