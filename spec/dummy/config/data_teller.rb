# The dummy app has no User model yet: these resolvers document the contract and are never called by the engine's specs.
DataTeller.configure do |c|
  c.tenant do
    model Account
    resolve { |user| user.account }
    time_zone { |account| account.time_zone }
  end
  c.roles { |user| user.roles }
  c.expose Order, Customer
end
