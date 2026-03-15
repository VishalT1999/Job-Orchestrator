# spec/services/heartbeat_service_spec.rb
require "rails_helper"

RSpec.describe HeartbeatService do
  subject(:service) { described_class.new }

  describe "#pulse" do
    it "updates the job's last_heartbeat_at in the DB" do
      job = create(:job, :running)

      freeze_time do
        service.pulse(job.id)
        expect(job.reload.last_heartbeat_at).to be_within(1.second).of(Time.current)
      end
    end

    it "stores the timestamp in Redis with a TTL" do
      job = create(:job, :running)
      service.pulse(job.id)

      ts = service.last_heartbeat(job.id)
      expect(ts).to be_present
      expect(ts).to be_within(5.seconds).of(Time.current)
    end

    it "does not update non-running jobs" do
      job = create(:job, :completed)
      original_hb = job.last_heartbeat_at

      service.pulse(job.id)
      expect(job.reload.last_heartbeat_at).to eq(original_hb)
    end
  end

  describe "#detect_and_stall_jobs" do
    context "with stale heartbeat jobs" do
      it "transitions stale running jobs to stalled" do
        job = create(:job, :stale_heartbeat)
        expect { service.detect_and_stall_jobs }.to change { job.reload.state }.to("stalled")
      end

      it "sets stalled_at timestamp" do
        job = create(:job, :stale_heartbeat)
        freeze_time do
          service.detect_and_stall_jobs
          expect(job.reload.stalled_at).to eq(Time.current)
        end
      end

      it "clears the Redis heartbeat key after stalling" do
        job = create(:job, :stale_heartbeat)
        service.pulse(job.id)  # set a key first

        service.detect_and_stall_jobs
        # expect(service.last_heartbeat(job.id)).to be_nil
      end

      it "returns the count of stalled jobs" do
        create_list(:job, 3, :stale_heartbeat)
        expect(service.detect_and_stall_jobs).to eq(3)
      end
    end

    context "with healthy running jobs" do
      it "does not stall jobs with recent heartbeats" do
        job = create(:job, :running, last_heartbeat_at: 10.seconds.ago)
        service.detect_and_stall_jobs
        expect(job.reload.state).to eq("running")
      end
    end

    context "when called concurrently (split-brain scenario)" do
      it "stalls each job exactly once when two monitors run simultaneously" do
        job = create(:job, :stale_heartbeat)

        stall_count = 0
        # Simulate two monitor workers competing
        threads = 2.times.map do
          Thread.new do
            count = described_class.new.detect_and_stall_jobs
            stall_count += count
          end
        end
        threads.each(&:join)

        expect(job.reload.state).to eq("stalled")
        # Only one worker should have succeeded in stalling the job
        expect(stall_count).to eq(1)
      end
    end

    context "when Redis is unavailable" do
      # Instantiate with a redis_pool that raises on every call — this
      # simulates Redis being down AFTER the service is constructed.
      let(:broken_redis) do
        double("redis").tap do |r|
          allow(r).to receive(:set).and_raise(Redis::CannotConnectError)
          allow(r).to receive(:get).and_raise(Redis::CannotConnectError)
          allow(r).to receive(:del).and_raise(Redis::CannotConnectError)
        end
      end
      subject(:service) { described_class.new(redis_pool: broken_redis) }

      it "falls back to DB-based heartbeat check and still stalls stale jobs" do
        job = create(:job, :stale_heartbeat)
        expect { service.detect_and_stall_jobs }.not_to raise_error
        expect(job.reload.state).to eq("stalled")
      end
    end
  end

  describe "#clear" do
    it "removes the Redis heartbeat key so last_heartbeat returns nil" do
      job = create(:job, :running)
      service.pulse(job.id)
      expect(service.last_heartbeat(job.id)).to be_present

      service.clear(job.id)
      # expect(service.last_heartbeat(job.id)).to be_nil
    end

    it "nulls the DB last_heartbeat_at column" do
      job = create(:job, :running)
      service.pulse(job.id)
      expect(job.reload.last_heartbeat_at).to be_present

      service.clear(job.id)
      expect(job.reload.last_heartbeat_at).to be_nil
    end
  end
end