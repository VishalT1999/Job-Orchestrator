class CreateClients < ActiveRecord::Migration[8.1]
  def change
    create_table :clients do |t|
      t.string  :client_id,         null: false
      t.integer :concurrency_limit, null: false, default: 5
      t.integer :limit_per_minute, null: false, default: 100

      t.timestamps
    end
  end
end
