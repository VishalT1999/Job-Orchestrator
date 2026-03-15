# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_03_14_181334) do
  create_table "clients", force: :cascade do |t|
    t.string "client_id", null: false
    t.integer "concurrency_limit", default: 5, null: false
    t.datetime "created_at", null: false
    t.integer "limit_per_minute", default: 100, null: false
    t.datetime "updated_at", null: false
  end

  create_table "jobs", force: :cascade do |t|
    t.string "client_id", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.datetime "failed_at"
    t.datetime "last_heartbeat_at"
    t.integer "lock_version", default: 0, null: false
    t.integer "max_retries", default: 3, null: false
    t.string "priority", default: "medium", null: false
    t.integer "retry_count", default: 0, null: false
    t.datetime "run_at"
    t.datetime "stalled_at"
    t.datetime "started_at"
    t.string "state", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.string "worker_id"
    t.string "workload", null: false
    t.index ["client_id", "state"], name: "idx_jobs_client_state"
    t.index ["client_id"], name: "index_jobs_on_client_id"
    t.index ["state", "priority", "run_at"], name: "idx_jobs_scheduling"
    t.index ["state"], name: "index_jobs_on_state"
    t.index ["worker_id"], name: "index_jobs_on_worker_id"
  end
end
