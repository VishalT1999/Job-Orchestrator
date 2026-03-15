# config/initializers/redis_pool.rb
#
# RedisPool — thread-safe Redis connection pool for application-level use.
#
# Sidekiq manages its own internal Redis pool separately.
# This pool is used by:
#   • ConcurrencyGuard  (Redlock acquire/release)
#   • FairnessScheduler (VFT INCRBYFLOAT / MGET)
#   • HeartbeatService  (SET with TTL / GET / DEL)
#   • RateLimiter       (ZADD / ZCARD / ZREMRANGEBYSCORE / EXPIRE)
#
# Pool sizing:
#   Match RAILS_MAX_THREADS (Puma threads) + Sidekiq concurrency.
#   Default 10 covers most single-server setups.
#   Override via REDIS_POOL_SIZE env var.
#
require "redis"
require "connection_pool"
require "singleton"

class RedisPool
  include Singleton

  POOL_SIZE    = ENV.fetch("REDIS_POOL_SIZE", 10).to_i
  POOL_TIMEOUT = 2  # seconds to wait for a free connection before raising

  REDIS_OPTIONS = {
    url:                ENV.fetch("REDIS_URL", "redis://localhost:6379/0"),
    timeout:            1,    # socket read/write timeout
    connect_timeout:    1,    # initial connection timeout
    reconnect_attempts: 2     # retry on transient network blips
  }.freeze

  # ---------------------------------------------------------------------------
  # Pool access
  # ---------------------------------------------------------------------------

  # Yields a Redis connection from the pool to the block.
  # Use this for multi-step pipelines where you need the same connection:
  #
  #   RedisPool.with { |r| r.multi { |p| p.set("k", "v"); p.expire("k", 60) } }
  #
  def with(&block)
    pool.with(&block)
  end

  # Delegates single Redis commands directly to a pooled connection.
  # Enables RedisPool.instance.get("key") without an explicit `with` block.
  #
  def method_missing(method, *args, **kwargs, &block)
    pool.with { |r| r.public_send(method, *args, **kwargs, &block) }
  end

  def respond_to_missing?(method, include_private = false)
    pool.with { |r| r.respond_to?(method, include_private) } || super
  end

  # ---------------------------------------------------------------------------
  # Health check — used by HealthController
  # ---------------------------------------------------------------------------

  def ping
    pool.with(&:ping)
  end

  def info(section = "all")
    pool.with { |r| r.info(section) }
  end

  # ---------------------------------------------------------------------------
  # Pool introspection (for /health/detailed)
  # ---------------------------------------------------------------------------

  def pool_stats
    {
      size:      pool.size,
      available: pool.available
    }
  end

  private

  def pool
    @pool ||= ConnectionPool.new(size: POOL_SIZE, timeout: POOL_TIMEOUT) do
      Redis.new(REDIS_OPTIONS)
    end
  end
end


# ---------------------------------------------------------------------------
# DB lock helper — used by services that need FOR UPDATE SKIP LOCKED.
# Returns the appropriate lock clause for the current DB adapter.
# SQLite (test) doesn't support FOR UPDATE, so we return nil (no lock).
# ---------------------------------------------------------------------------
module DbLock
  SKIP_LOCKED = "FOR UPDATE SKIP LOCKED"
  FOR_UPDATE   = "FOR UPDATE"

  def self.skip_locked
    mysql? ? SKIP_LOCKED : nil
  end

  def self.for_update
    mysql? ? FOR_UPDATE : nil
  end

  def self.mysql?
    ActiveRecord::Base.connection.adapter_name =~ /mysql/i
  end
end