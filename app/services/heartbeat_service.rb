# app/services/heartbeat_service.rb
#
# HeartbeatService manages the Dead Man's Switch for running jobs.
#
# Each running job must call #pulse every ≤20 seconds.
# A Sidekiq-scheduler cron (HeartbeatMonitorWorker) calls #detect_stalled
# every 15 seconds to find jobs whose heartbeat has expired.
#
class HeartbeatService
  HEARTBEAT_INTERVAL = 20   # seconds — how often workers should pulse
  STALL_THRESHOLD    = 60   # seconds — no pulse within this → stalled
  REDIS_TTL          = STALL_THRESHOLD + 30  # extra buffer

  # Lazy-initialize Redis so construction never raises even when Redis is
  # unavailable.  Every method that touches Redis rescues connection errors
  # and falls back to the DB last_heartbeat_at column.
  def initialize(redis_pool: nil)
    @redis_pool = redis_pool  # nil means "resolve lazily via RedisPool.instance"
  end

  # Called by the job worker every HEARTBEAT_INTERVAL seconds.
  def pulse(job_id)
    with_redis { |r| r.set(redis_key(job_id), Time.current.to_i, ex: REDIS_TTL) }
    Job.where(id: job_id, state: "running")
       .update_all(last_heartbeat_at: Time.current)
  end

  # Returns Time of last heartbeat from Redis, or nil if key missing / Redis down.
  def last_heartbeat(job_id)
    ts = with_redis { |r| r.get(redis_key(job_id)) }
    ts ? Time.at(ts.to_i) : nil
  rescue StandardError
    nil
  end

  # Clear heartbeat from both Redis AND the DB column so last_heartbeat()
  # returns nil after a job is stalled or completed.
  def clear(job_id)
    with_redis { |r| r.del(redis_key(job_id)) }
    Job.where(id: job_id).update_all(last_heartbeat_at: nil)
  end

  # Transition all stalled jobs.  Returns count of jobs stalled.
  def detect_and_stall_jobs
    stalled_count = 0

    Job.stale_heartbeat.find_each do |job|
      stalled = false

      begin
        ActiveRecord::Base.transaction do
          lock  = DbLock.skip_locked
          fresh = if lock
                    Job.lock(lock).find_by(id: job.id, state: "running")
                  else
                    Job.find_by(id: job.id, state: "running")
                  end
          next unless fresh

          if heartbeat_expired?(fresh)
            fresh.stall!
            Rails.logger.warn("[HeartbeatService] stalled job=#{fresh.id} client=#{fresh.client_id}")
            stalled = fresh.id
            stalled_count += 1
          end
        end
      rescue StateMachines::InvalidTransition, ActiveRecord::StaleObjectError => e
        Rails.logger.info("[HeartbeatService] skipped job=#{job.id}: #{e.message}")
      end

      # Clear Redis key OUTSIDE the transaction — Redis ops are not
      # transactional and must not be rolled back with the DB transaction.
      clear(stalled) if stalled
    end

    stalled_count
  end

  private

  def redis_key(job_id)
    "heartbeat:#{job_id}"
  end

  def heartbeat_expired?(job)
    last = last_heartbeat(job.id) || job.last_heartbeat_at
    return true if last.nil?
    last < STALL_THRESHOLD.seconds.ago
  end

  # Yields a Redis connection; swallows connection errors so callers
  # automatically fall back to DB-only logic when Redis is unavailable.
  def with_redis
    redis = @redis_pool ||= RedisPool.instance
    yield redis
  rescue Redis::CannotConnectError, Redis::ConnectionError, RedisClient::CannotConnectError => e
    Rails.logger.warn("[HeartbeatService] Redis unavailable: #{e.message}")
    nil
  end
end