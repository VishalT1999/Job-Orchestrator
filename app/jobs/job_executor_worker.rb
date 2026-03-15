# app/workers/job_executor_worker.rb
#
# JobExecutorWorker is the **Executor** half.
#
# It receives a job_id, runs the simulated workload, pulses heartbeats,
# and transitions the job to completed or failed.
#
# Idempotency:
#   The worker starts by checking the job is still in :running state.
#   If the job was stalled or completed between dispatch and execution,
#   it exits cleanly.  The concurrency slot was released by the state
#   transition (slot counting is DB-derived, not a counter).
#
# At-least-once semantics:
#   Sidekiq retries are disabled here (retry: 0) because our own retry
#   logic (exponential backoff + requeue) is more sophisticated.  Sidekiq
#   may still re-deliver if a process crashes before `ack` (dead-letter
#   queue pattern); idempotency guards handle this case.
#
class JobExecutorWorker
  include Sidekiq::Job

  sidekiq_options queue: :executor, retry: 0

  HEARTBEAT_INTERVAL = 20  # seconds

  def perform(job_id)
    job = Job.find_by(id: job_id)
    return unless job
    return unless job.running?  # idempotency: skip if already terminal

    heartbeat_service = HeartbeatService.new
    guard             = ConcurrencyGuard.new

    begin
      run_with_heartbeat(job, heartbeat_service)

      ActiveRecord::Base.transaction do
        fresh = Job.lock("FOR UPDATE").find(job.id)
        fresh.complete! if fresh.running?
      end
    rescue => e
      handle_failure(job, e)
    ensure
      heartbeat_service.clear(job_id)
      guard.release(job)
    end
  end

  private

  def run_with_heartbeat(job, heartbeat_service)
    # Run the workload in a thread so we can pulse heartbeats from the main thread.
    workload_thread = Thread.new { simulate_workload(job) }

    until workload_thread.join(HEARTBEAT_INTERVAL)
      heartbeat_service.pulse(job.id)
    end

    # Surface any exception from the workload thread
    workload_thread.value
  end

  def simulate_workload(job)
    # In production, replace this with the real task dispatcher.
    # The workload field is treated as a task identifier.
    Rails.logger.info("[Executor] starting job=#{job.id} workload=#{job.workload}")

    task_duration = case job.workload
                    when "fast_task"    then rand(1..5)
                    when "slow_task"    then rand(30..90)
                    when "flaky_task"   then raise "Simulated transient error" if rand < 0.3; rand(5..15)
                    else rand(5..30)
                    end

    sleep(task_duration)
    Rails.logger.info("[Executor] completed job=#{job.id} after #{task_duration}s")
  end

  def handle_failure(job, error)
    Rails.logger.error("[Executor] job=#{job.id} failed: #{error.message}")

    ActiveRecord::Base.transaction do
      fresh = Job.lock("FOR UPDATE").find(job.id)
      return unless fresh.running?

      fresh.update_columns(error_message: error.message.truncate(1000))
      fresh.mark_failed!

      # Schedule retry if attempts remain
      if fresh.retries_remaining?
        RetryJobWorker.perform_in(fresh.next_retry_delay, fresh.id)
      end
    end
  rescue => e
    Rails.logger.error("[Executor] error handling failure for job=#{job.id}: #{e.message}")
  end
end