# app/models/job.rb
#
# State machine powered by state_machines-activerecord.
#
# Key differences from AASM:
#   • Transition callbacks receive the transition object — you know exactly
#     what from/to states triggered the callback.
#   • Guards are `if:` conditions on the transition definition — cleaner DSL.
#   • Invalid transitions return false (bang methods raise
#     StateMachines::InvalidTransition) — no surprise exceptions on checks.
#   • state_machines integrates directly with ActiveRecord validations and
#     dirty tracking; no separate `include` needed.
#
class Job < ApplicationRecord
  PRIORITIES = %w[low medium high].freeze
  PRIORITY_WEIGHTS = { "high" => 3, "medium" => 2, "low" => 1 }.freeze

  belongs_to :client

  validates :client_id, presence: true
  validates :priority,  inclusion: { in: PRIORITIES }
  validates :workload,  presence: true

  # Optimistic locking — a second concurrent writer on the same row raises
  # ActiveRecord::StaleObjectError, which callers rescue as a rejected transition.
  self.locking_column = :lock_version

  state_machine :state, initial: :queued do
    # ------------------------------------------------------------------
    # Auditing hooks — fire on every transition regardless of direction
    # ------------------------------------------------------------------
    after_transition do |job, transition|
      Rails.logger.info(
        "[Job##{job.id}] #{transition.from} → #{transition.to} " \
        "via :#{transition.event} (client=#{job.client_id})"
      )
    end

    # ------------------------------------------------------------------
    # Events
    # ------------------------------------------------------------------

    # queued → running
    # Guard: concurrency quota must have a free slot.
    # After:  stamp started_at and seed the first heartbeat.
    event :start do
      transition queued: :running, if: :concurrency_quota_available?
    end

    after_transition on: :start do |job, _transition|
      job.update_columns(
        started_at:        Time.current,
        last_heartbeat_at: Time.current
      )
    end

    # running → completed
    event :complete do
      transition running: :completed
    end

    after_transition on: :complete do |job, _transition|
      job.update_columns(completed_at: Time.current)
    end

    # running → failed
    # Named :mark_failed because :fail conflicts with Ruby's built-in
    # Kernel#fail (alias for raise) — calling job.fail! would raise
    # RuntimeError instead of triggering the state machine.
    event :mark_failed do
      transition running: :failed
    end

    after_transition on: :mark_failed do |job, _transition|
      job.update_columns(failed_at: Time.current)
    end

    # running → stalled  (triggered by HeartbeatMonitorWorker)
    event :stall do
      transition running: :stalled
    end

    after_transition on: :stall do |job, _transition|
      job.update_columns(stalled_at: Time.current)
    end

    # failed|stalled → queued  (exponential-backoff retry)
    # Guard: retries_remaining? prevents infinite loops.
    # After:  increment retry_count and set future run_at.
    event :requeue do
      transition %i[failed stalled] => :queued, if: :retries_remaining?
    end

    after_transition on: :requeue do |job, _transition|
      delay = job.next_retry_delay
      job.update_columns(
        retry_count:   job.retry_count + 1,
        run_at:        Time.current + delay,
        error_message: nil,
        worker_id:     nil
      )
    end

    # ------------------------------------------------------------------
    # State predicates generated automatically by state_machines:
    #   job.queued?    job.running?    job.completed?
    #   job.failed?    job.stalled?
    # ------------------------------------------------------------------
  end

  # ---------------------------------------------------------------------------
  # Scopes
  # ---------------------------------------------------------------------------
  scope :runnable, -> {
    where(state: "queued").where("run_at IS NULL OR run_at <= ?", Time.current)
  }

  scope :stale_heartbeat, -> {
    where(state: "running")
      .where("last_heartbeat_at < ? OR last_heartbeat_at IS NULL", 60.seconds.ago)
  }

  # DB-agnostic priority ordering (FIELD() is MySQL-only; CASE WHEN works
  # on MySQL, SQLite, and PostgreSQL). High → medium → low, then FIFO.
  PRIORITY_ORDER_SQL = Arel.sql(
    "CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 WHEN 'low' THEN 2 ELSE 3 END"
  ).freeze

  scope :by_priority, -> {
    order(PRIORITY_ORDER_SQL, :created_at)
  }

  # ---------------------------------------------------------------------------
  # Public helpers
  # ---------------------------------------------------------------------------

  def retries_remaining?
    retry_count < max_retries
  end

  # Backoff: 2^retry_count × 30 s, capped at 1 hour.
  #   attempt 0 →  30 s
  #   attempt 1 →  60 s
  #   attempt 2 → 120 s  … → 3 600 s max
  def next_retry_delay
    [2**retry_count * 30, 3600].min
  end

  # ---------------------------------------------------------------------------
  private
  # ---------------------------------------------------------------------------

  # Lightweight quota guard evaluated by the state machine before start!.
  # ConcurrencyGuard#acquire! is the authoritative, distributed-lock-protected
  # path used by the Scheduler.  This guard is a safety net for any direct
  # model-level calls (tests, console, etc.).
  def concurrency_quota_available?
    client_record = Client.find_by(client_id: client_id)
    return true if client_record.nil?

    running_count = Job.where(client_id: client_id, state: "running").count
    running_count < client_record.concurrency_limit
  end
end