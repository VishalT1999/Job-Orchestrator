# app/services/fairness_scheduler.rb
#
# FairnessScheduler implements **Weighted Fair Queuing** across clients.
#
# Algorithm:
#   Each client gets a "virtual finish time" (VFT) counter stored in Redis.
#   When a job is selected for execution its client's counter is incremented
#   by (1 / priority_weight).  The scheduler always picks the runnable job
#   belonging to the client with the *lowest* VFT, breaking ties by
#   job priority and then FIFO.
#
#   This ensures:
#     • High-priority jobs within a client run first.
#     • A client that floods the queue accumulates a large VFT and is
#       deprioritized relative to quieter clients — preventing starvation.
#     • VFTs are stored in Redis with a 24 h TTL; a Redis flush resets all
#       counters to 0, which restores full fairness (no permanent starvation).
#
# Complexity: O(K) where K = number of distinct queued client_ids — typically
# small.  For 100 k jobs/hour with 1 000 clients this is negligible.
#
class FairnessScheduler
  VFT_KEY_PREFIX = "vft:"
  VFT_TTL        = 86_400  # 24 h

  def initialize(redis_pool: RedisPool.instance)
    @redis = redis_pool
  end

  # Return the next Job that should run, or nil if nothing is runnable.
  # Does NOT transition state — that is the caller's responsibility.
  def next_job
    # 1. Fetch all distinct client_ids with runnable jobs.
    client_ids = Job.runnable.distinct.pluck(:client_id)
    return nil if client_ids.empty?

    # 2. Fetch virtual finish times for all clients in one Redis pipeline.
    vfts = fetch_vfts(client_ids)

    # 3. Sort clients by VFT ascending (least-served first).
    ordered_clients = client_ids.sort_by { |cid| vfts[cid] }

    # 4. For each client (in VFT order), find their highest-priority runnable job.
    ordered_clients.each do |client_id|
      job = Job.runnable
               .where(client_id: client_id)
               .by_priority
               .first
      return job if job
    end

    nil
  end

  # Record that a job has been dispatched and update the client's VFT.
  def record_dispatch(job)
    weight = Job::PRIORITY_WEIGHTS.fetch(job.priority, 1)
    increment = 1.0 / weight  # higher priority → smaller increment → stays competitive

    @redis.multi do |pipe|
      pipe.incrbyfloat(vft_key(job.client_id), increment)
      pipe.expire(vft_key(job.client_id), VFT_TTL)
    end
  end

  # Peek at the VFT for a client (useful for observability).
  def vft_for(client_id)
    @redis.get(vft_key(client_id)).to_f
  end

  private

  def vft_key(client_id)
    "#{VFT_KEY_PREFIX}#{client_id}"
  end

  def fetch_vfts(client_ids)
    # key example vft:client_id
    keys   = client_ids.map { |cid| vft_key(cid) }
    values = @redis.mget(*keys)
    client_ids.zip(values).to_h { |cid, v| [cid, v.to_f] }
  end
end