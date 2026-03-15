# spec/requests/jobs_spec.rb
require "rails_helper"

RSpec.describe "POST /api/v1/jobs", type: :request do
  let(:client) { create(:client, client_id: "acme") }
  let(:valid_params) do
    { job: { client_id: "acme", priority: "high", workload: "fast_task" } }
  end

  before { client }  # ensure client exists

  describe "POST /api/v1/jobs" do
    context "with valid parameters" do
      it "returns 201 Created" do
        post "/api/v1/jobs", params: valid_params, as: :json
        expect(response).to have_http_status(:created)
      end

      it "returns the job id and initial state" do
        post "/api/v1/jobs", params: valid_params, as: :json
        json = response.parsed_body

        expect(json["id"]).to be_present
        expect(json["state"]).to eq("queued")
        expect(json["client_id"]).to eq("acme")
        expect(json["priority"]).to eq("high")
      end

      it "persists the job to the database" do
        expect {
          post "/api/v1/jobs", params: valid_params, as: :json
        }.to change(Job, :count).by(1)
      end

      it "enqueues a JobDispatcherWorker" do
        expect {
          post "/api/v1/jobs", params: valid_params, as: :json
        }.to change(JobDispatcherWorker.jobs, :size).by(1)
      end
    end

    context "with invalid priority" do
      it "returns 422" do
        post "/api/v1/jobs",
             params: { job: valid_params[:job].merge(priority: "urgent") },
             as: :json
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    context "with missing client_id" do
      it "returns 422" do
        post "/api/v1/jobs",
             params: { job: { priority: "medium", workload: "fast_task" } },
             as: :json
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    context "when rate limit is exceeded" do
      before do
        client.update!(limit_per_minute: 2)
        allow_any_instance_of(RateLimiter).to receive(:check!).and_raise(
          RateLimiter::RateLimitExceeded.new("acme", 2, 30)
        )
      end

      it "returns 429 Too Many Requests" do
        post "/api/v1/jobs", params: valid_params, as: :json
        expect(response).to have_http_status(:too_many_requests)
      end

      it "sets Retry-After header" do
        post "/api/v1/jobs", params: valid_params, as: :json
        expect(response.headers["Retry-After"]).to be_present
      end
    end

    context "default priority" do
      it "defaults to medium when priority is not supplied" do
        post "/api/v1/jobs",
             params: { job: { client_id: "acme", workload: "fast_task" } },
             as: :json
        expect(response.parsed_body["priority"]).to eq("medium")
      end
    end
  end

  describe "GET /api/v1/jobs/:id" do
    let(:job) { create(:job, :running, client_id: client.client_id) }

    it "returns job details" do
      get "/api/v1/jobs/#{job.id}", as: :json
      expect(response).to have_http_status(:ok)

      json = response.parsed_body
      expect(json["id"]).to eq(job.id)
      expect(json["state"]).to eq("running")
    end

    it "returns 404 for unknown job" do
      get "/api/v1/jobs/99999999", as: :json
      expect(response).to have_http_status(:not_found)
    end
  end
end