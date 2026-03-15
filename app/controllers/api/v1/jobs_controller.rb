# app/controllers/api/v1/jobs_controller.rb
module Api
  module V1
    class JobsController < ApplicationController
      skip_before_action :verify_authenticity_token
      before_action :set_job, only: %i[show]

      # POST /jobs
      def create
        client_id = job_params[:client_id].to_s.strip
        return render_error("client_id is required", :unprocessable_entity) if client_id.blank?

        # Rate limiting — raises RateLimiter::RateLimitExceeded if exceeded
        RateLimiter.new.check!(client_id)

        # Provision client row if first time we've seen this client_id
        client = Client.find_or_provision!(client_id)

        job = Job.new(
          client_id: client.id,
          priority:  job_params[:priority] || "medium",
          workload:  job_params[:workload]
        )

        if job.save
          # Kick the dispatcher so it processes this job soon rather than
          # waiting for the next 5-second scheduler tick.
          JobDispatcherWorker.perform_async

          render json: {
            job_id:         job.id,
            client_id:  job.client_id,
            priority:   job.priority,
            workload:   job.workload,
            state:      job.state,
            created_at: job.created_at
          }, status: :created
        else
          render_error(job.errors.full_messages, :unprocessable_entity)
        end

      rescue RateLimiter::RateLimitExceeded => e
        response.headers["Retry-After"] = e.retry_after.to_s
        render_error(e.message, :too_many_requests)
      rescue => e
        Rails.logger.error("[JobsController#create] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        render_error("Internal server error", :internal_server_error)
      end

      # GET /jobs/:id
      def show
        render json: {
          id:                  @job.id,
          client_id:           @job.client_id,
          priority:            @job.priority,
          workload:            @job.workload,
          state:               @job.state,
          retry_count:         @job.retry_count,
          error_message:       @job.error_message,
          last_heartbeat_at:   @job.last_heartbeat_at,
          started_at:          @job.started_at,
          completed_at:        @job.completed_at,
          created_at:          @job.created_at
        }
      end

      private

      def set_job
        @job = Job.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render_error("Job not found", :not_found)
      end

      def job_params
        params.require(:job).permit(:client_id, :priority, :workload)
      end

      def render_error(message, status)
        render json: { error: Array(message).join(", ") }, status: status
      end
    end
  end
end