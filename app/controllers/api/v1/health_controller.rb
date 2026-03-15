# app/controllers/api/v1/health_controller.rb
module Api
  module V1
    class HealthController < ApplicationController
      SIDEKIQ_LATENCY_THRESHOLD = 15.0  # seconds

      # GET /health/detailed
      def detailed
        components = {
          database: check_database,
          redis:    check_redis,
          sidekiq:  check_sidekiq
        }

        all_healthy = components.values.all? { |c| c[:status] == "ok" }
        http_status = all_healthy ? :ok : :service_unavailable

        render json: {
          status:     all_healthy ? "healthy" : "degraded",
          checked_at: Time.current.iso8601,
          components: components
        }, status: http_status
      end

      private

      def check_database
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        ActiveRecord::Base.connection.execute("SELECT 1")
        latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(2)

        {
          status:     "ok",
          latency_ms: latency_ms,
          pool_size:  ActiveRecord::Base.connection_pool.size,
          pool_used:  ActiveRecord::Base.connection_pool.stat[:busy]
        }
      rescue => e
        { status: "error", error: e.message }
      end

      def check_redis
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        RedisPool.instance.ping
        latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(2)

        info = RedisPool.instance.info("server")

        {
          status:     "ok",
          latency_ms: latency_ms,
          version:    info["redis_version"],
          used_memory: info["used_memory_human"]
        }
      rescue => e
        { status: "error", error: e.message }
      end

      def check_sidekiq
        stats   = Sidekiq::Stats.new
        queues  = Sidekiq::Queue.all.map do |q|
          { name: q.name, size: q.size, latency: q.latency.round(2) }
        end

        default_queue   = Sidekiq::Queue.new("default")
        default_latency = default_queue.latency

        # Failure condition: default queue latency > threshold
        latency_ok = default_latency <= SIDEKIQ_LATENCY_THRESHOLD

        {
          status:           latency_ok ? "ok" : "degraded",
          processed:        stats.processed,
          failed:           stats.failed,
          enqueued:         stats.enqueued,
          dead:             stats.dead_size,
          default_latency:  default_latency.round(2),
          latency_ok:       latency_ok,
          queues:           queues
        }
      rescue => e
        { status: "error", error: e.message }
      end
    end
  end
end