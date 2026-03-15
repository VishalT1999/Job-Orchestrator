# spec/requests/health_spec.rb
require "rails_helper"

RSpec.describe "GET /health/detailed", type: :request do
  let(:sidekiq_stats)  { instance_double(Sidekiq::Stats, processed: 100, failed: 2, enqueued: 5, dead_size: 0) }
  let(:default_queue)  { instance_double(Sidekiq::Queue, name: "default", size: 2, latency: 0.5) }

  before do
    allow(Sidekiq::Stats).to receive(:new).and_return(sidekiq_stats)
    allow(Sidekiq::Queue).to receive(:all).and_return([default_queue])
    allow(Sidekiq::Queue).to receive(:new).with("default").and_return(default_queue)
  end

  context "when all components are healthy" do
    it "returns 200 OK" do
      get "/health/detailed", as: :json
      expect(response).to have_http_status(:ok)
    end

    it "reports all components as ok" do
      get "/health/detailed", as: :json
      json = response.parsed_body

      expect(json["status"]).to eq("healthy")
      expect(json["components"]["database"]["status"]).to eq("ok")
      expect(json["components"]["redis"]["status"]).to eq("ok")
      expect(json["components"]["sidekiq"]["status"]).to eq("ok")
    end

    it "includes latency data" do
      get "/health/detailed", as: :json
      json = response.parsed_body

      expect(json["components"]["database"]["latency_ms"]).to be_a(Numeric)
      expect(json["components"]["sidekiq"]["default_latency"]).to eq(0.5)
    end
  end

  context "when database is down" do
    before do
      allow(ActiveRecord::Base.connection).to receive(:execute).and_raise(
        ActiveRecord::StatementInvalid, "MySQL connection lost"
      )
    end

    it "returns 503 Service Unavailable" do
      get "/health/detailed", as: :json
      expect(response).to have_http_status(:service_unavailable)
    end

    it "reports database as error" do
      get "/health/detailed", as: :json
      json = response.parsed_body
      expect(json["components"]["database"]["status"]).to eq("error")
    end
  end

  context "when Redis is down" do
    before do
      allow(RedisPool.instance).to receive(:ping).and_raise(Redis::CannotConnectError)
    end

    it "returns 503 Service Unavailable" do
      get "/health/detailed", as: :json
      expect(response).to have_http_status(:service_unavailable)
    end
  end

  context "when Sidekiq latency exceeds 15 seconds" do
    let(:slow_queue) { instance_double(Sidekiq::Queue, name: "default", size: 500, latency: 20.0) }

    before do
      allow(Sidekiq::Queue).to receive(:all).and_return([slow_queue])
      allow(Sidekiq::Queue).to receive(:new).with("default").and_return(slow_queue)
    end

    it "returns 503 Service Unavailable" do
      get "/health/detailed", as: :json
      expect(response).to have_http_status(:service_unavailable)
    end

    it "reports sidekiq as degraded" do
      get "/health/detailed", as: :json
      json = response.parsed_body
      expect(json["components"]["sidekiq"]["status"]).to eq("degraded")
      expect(json["components"]["sidekiq"]["latency_ok"]).to be false
    end
  end
end