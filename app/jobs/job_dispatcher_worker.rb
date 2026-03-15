# app/workers/job_dispatcher_worker.rb
#
# JobDispatcherWorker is the **Scheduler** half of the system.
#
# It is enqueued by Sidekiq-Scheduler every 5 seconds on a dedicated
# :scheduler queue with a single concurrency thread (concurrency: 1 in
# sidekiq.yml).  This serialises scheduling decisions so we avoid
# thundering-herd contention on the quota logic.
#
# Flow:
#   1. Ask FairnessScheduler for the next runnable job.
#   2. Ask ConcurrencyGuard to acquire the slot (atomic DB transition).
#   3. Enqueue JobExecutorWorker to actually run the workload.
#   4. Repeat until no runnable jobs remain or all quotas are full.
#
class JobDispatcherWorker
  include Sidekiq::Job

  sidekiq_options queue: :scheduler, retry: false

  DISPATCH_BATCH = 50  # max jobs to dispatch per scheduler tick

  def perform
    scheduler = FairnessScheduler.new
    guard     = ConcurrencyGuard.new
    dispatched = 0

    DISPATCH_BATCH.times do
      job = scheduler.next_job
      break if job.nil?

      begin
        acquired = guard.acquire!(job)
        if acquired
          scheduler.record_dispatch(job)
          JobExecutorWorker.perform_async(job.id)
          dispatched += 1
        end
      rescue ConcurrencyGuard::LockTimeout => e
        Rails.logger.warn("[Dispatcher] lock timeout: #{e.message}")
        break  # back off; next tick will retry
      rescue ConcurrencyGuard::QuotaExceeded
        # This client is at capacity — try the next client.
        # FairnessScheduler will give us a different client next iteration
        # but we need to prevent re-selecting the same client.
        next
      end
    end

    Rails.logger.info("[Dispatcher] dispatched #{dispatched} jobs") if dispatched > 0
  end
end