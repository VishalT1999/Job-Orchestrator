class CreateJobs < ActiveRecord::Migration[8.1]
  def change
    create_table :jobs do |t|
      t.string   :client_id,    null: false
      t.string   :priority,     null: false, default: "medium"
      t.string   :workload,     null: false
      t.string   :state,        null: false, default: "queued"
      t.integer  :retry_count,  null: false, default: 0
      t.integer  :max_retries,  null: false, default: 3
      t.datetime :last_heartbeat_at
      t.datetime :started_at
      t.datetime :completed_at
      t.datetime :failed_at
      t.datetime :stalled_at
      t.datetime :run_at                   # earliest time this job may be retried
      t.text     :error_message
      t.string   :worker_id                # which Sidekiq worker holds this job
      t.integer  :lock_version, null: false, default: 0   # optimistic lock

      t.timestamps
    end

    add_index :jobs, :client_id
    add_index :jobs, :state
    add_index :jobs, [:state, :priority, :run_at], name: "idx_jobs_scheduling"
    add_index :jobs, [:client_id, :state],          name: "idx_jobs_client_state"
    add_index :jobs, :worker_id
  end
end
