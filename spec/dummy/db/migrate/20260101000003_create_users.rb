class CreateUsers < ActiveRecord::Migration[7.2]
  def change
    create_table :users do |t|
      t.references :account, null: false, foreign_key: true
      t.string :email, null: false
      t.string :role, null: false
      t.timestamps
    end
  end
end
