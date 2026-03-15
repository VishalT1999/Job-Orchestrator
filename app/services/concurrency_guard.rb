# app/services/concurrency_guard.rb
#
# ConcurrencyGuard is the single authority for acquiring and releasing
# per-client concurrency slots.
#
# Design:
#   1. A Redlock distributed mutex prevents two schedulers on different nodes
#      from simultaneously granting the last slot to two different jobs.
#   2. Inside the lock, we query the DB for the *current* concurrency_limit
#      (so a quota reduction is respected immediately) and count running jobs.
#   3. The actual state transition happens inside a DB transaction with a
#      pessimistic row-lock on the Job record, so a SIGKILL after the Redis
#      lock releases but before the DB commit leaves the job in :queued —
#      the slot was never incremented.
#   4. Slot *release* is purely DB-derived: we count running rows.  There is
#      no Redis counter to drift, so a Redis flush cannot leak slots.
#
class ConcurrencyGuard
  LOCK_TTL_MS   = 5_000   # 5 s — enough for one DB round-trip
  LOCK_RETRIES  = 3

  class QuotaExceeded < StandardError; end
  class LockTimeout   < StandardError; end

  def initialize(redis_pool: RedisPool.instance, lock_manager: nil)
    @redis_pool   = redis_pool
    @lock_manager = lock_manager || Redlock::Client.new(
      [redis_pool],
      retry_count: LOCK_RETRIES,
      retry_delay: 200  # ms
    )
  end

  # Attempt to transition a job from queued → running.
  # Returns true on success, raises QuotaExceeded / LockTimeout on failure.
  def acquire!(job)
    lock_key = "concurrency:#{job.client_id}"

    locked = @lock_manager.lock(lock_key, LOCK_TTL_MS)
    raise LockTimeout, "Could not acquire concurrency lock for #{job.client_id}" unless locked

    begin
      ActiveRecord::Base.transaction do
        # Re-fetch with pessimistic lock so no other thread can transition
        # the same job concurrently.
        fresh = Job.lock("FOR UPDATE SKIP LOCKED").find_by(id: job.id, state: "queued")
        return false if fresh.nil?  # job was claimed by another worker

        client  = Client.find_or_provision!(job.client_id)
        running = Job.where(client_id: job.client_id, state: "running").count

        raise QuotaExceeded, "Quota full for #{job.client_id} (#{running}/#{client.concurrency_limit})" if running >= client.concurrency_limit

        fresh.worker_id = current_worker_id
        fresh.start!   # state_machines transition; raises StateMachines::InvalidTransition if guard fails
      end
    ensure
      @lock_manager.unlock(locked)
    end

    true
  rescue StateMachines::InvalidTransition
    false  # another scheduler beat us to this job
  end

  # Release is implicit: no counter to decrement.
  # Call this to confirm the slot is freed in any observability code.
  def release(job)
    # No-op: slot counting is always derived from DB state
    # This method exists so callers have a symmetric API and we can add
    # instrumentation / Redis hints here in the future.
    Rails.logger.info("[ConcurrencyGuard] released slot for job=#{job.id} client=#{job.client_id}")
  end

  # How many slots are currently in use for a client (live DB query).
  def slots_in_use(client_id)
    Job.where(client_id: client_id, state: "running").count
  end

  # Current quota from DB (always fresh — no caching).
  def quota_for(client_id)
    Client.find_by(client_id: client_id)&.concurrency_limit || 5
  end

  private

  def current_worker_id
    "#{Socket.gethostname}:#{Process.pid}:#{Thread.current.object_id}"
  end
end