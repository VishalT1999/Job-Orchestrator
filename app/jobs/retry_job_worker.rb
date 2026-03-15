# app/workers/retry_job_worker.rb
#
# RetryJobWorker transitions a failed/stalled job back to :queued, then
# immediately kicks JobDispatcherWorker so the job is picked up without
# waiting for the next 5-second scheduler tick.
#
# Flow:
#   JobExecutorWorker (on failure) / HeartbeatMonitorWorker (on stall)
#     → RetryJobWorker.perform_in(backoff_delay, job_id)
#       → requeue! (failed|stalled → queued)
#       → JobDispatcherWorker.perform_async   ← re-trigger, not create
#
class RetryJobWorker
  include Sidekiq::Job

  sidekiq_options queue: :scheduler, retry: 3

  def perform(job_id)
    job = Job.find_by(id: job_id)
    return unless job

    # Reload so the state machine reflects what's actually in the DB column
    # (FactoryBot writes state directly; in-memory object may be stale).
    job.reload

    return if job.queued? || job.running? || job.completed?

    begin
      ActiveRecord::Base.transaction do
        # FOR UPDATE is MySQL/PostgreSQL only — SQLite (test env) ignores it.
        lock_clause = ActiveRecord::Base.connection.adapter_name =~ /mysql/i ? "FOR UPDATE" : nil
        fresh = lock_clause ? Job.lock(lock_clause).find(job.id) : Job.find(job.id)
        return if fresh.queued? || fresh.running? || fresh.completed?

        fresh.requeue!
        Rails.logger.info("[RetryJobWorker] requeued job=#{fresh.id} attempt=#{fresh.retry_count}")
      end

      # Re-trigger the existing dispatcher — don't create a new scheduler,
      # just wake it up so it processes the newly-queued job promptly.
      JobDispatcherWorker.perform_async

    rescue StateMachines::InvalidTransition => e
      Rails.logger.warn("[RetryJobWorker] invalid transition for job=#{job_id}: #{e.message}")
    rescue ActiveRecord::StaleObjectError
      # Another process already requeued — safe to ignore
    end
  end
end