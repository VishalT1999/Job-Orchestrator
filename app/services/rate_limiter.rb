# Sliding-window rate limiter backed by a Redis sorted set.
# Prevents a single client from overwhelming the submission endpoint.

class RateLimiter
  WINDOW_SECONDS = 60

  def initialize(redis_pool: RedisPool.instance)
    @redis = redis_pool
  end

  # Raises RateLimitExceeded if the client has exceeded their per-minute quota.
  def check!(client_id)
    limit  = Client.find_by(client_id: client_id)&.limit_per_minute || 100
    now    = Time.current.to_f
    window_start = now - WINDOW_SECONDS
    key    = "rate:#{client_id}"

    count = @redis.multi do |pipe|
      # Remove entries outside the sliding window
      pipe.zremrangebyscore(key, "-inf", window_start)
      # Add current timestamp
      pipe.zadd(key, now, "#{now}:#{SecureRandom.hex(4)}")
      # Count entries in window
      pipe.zcard(key)
      # Set TTL
      pipe.expire(key, WINDOW_SECONDS * 2)
    end[2]  # zcard result is index 2

    if count > limit
      retry_after = WINDOW_SECONDS - (now - @redis.zrange(key, 0, 0, with_scores: true).first&.last.to_f)
      raise RateLimitExceeded.new(client_id, limit, [retry_after.ceil, 1].max)
    end
  end

  # custom exception
  class RateLimitExceeded < StandardError
    attr_reader :retry_after

    def initialize(client_id, limit, retry_after)
      @retry_after = retry_after
      super("Rate limit exceeded for #{client_id}: max #{limit} submissions/minute")
    end
  end
end