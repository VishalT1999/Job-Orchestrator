# app/workers/heartbeat_monitor_worker.rb
#
# Runs every 15 seconds via Sidekiq-Scheduler.
# Single concurrency (see sidekiq.yml) to avoid two monitors stalling
# the same job simultaneously.  Even if two run at the same time, the
# FOR UPDATE SKIP LOCKED in HeartbeatService#detect_and_stall_jobs means
# only one succeeds per job — the other skips it cleanly.
#
class HeartbeatMonitorWorker
  include Sidekiq::Job

  sidekiq_options queue: :monitor, retry: false

  def perform
    count = HeartbeatService.new.detect_and_stall_jobs
    Rails.logger.info("[HeartbeatMonitor] stalled #{count} jobs") if count > 0
  end
end