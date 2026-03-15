# spec/services/concurrency_guard_spec.rb
require "rails_helper"

RSpec.describe ConcurrencyGuard do
  let(:client)  { create(:client, concurrency_limit: 2) }
  let(:guard)   { described_class.new(lock_manager: fake_lock_manager) }

  # Use a simple stub lock manager that always succeeds
  let(:fake_lock_manager) do
    instance_double(Redlock::Client).tap do |lm|
      allow(lm).to receive(:lock).and_return({ validity: 5000, resource: "lock", value: "val" })
      allow(lm).to receive(:unlock)
    end
  end

  describe "#acquire!" do
    context "when quota is available" do
      it "transitions the job to running" do
        job = create(:job, client_id: client.client_id)
        result = guard.acquire!(job)

        expect(result).to be true
        expect(job.reload.state).to eq("running")
      end

      it "sets the worker_id on the job" do
        job = create(:job, client_id: client.client_id)
        guard.acquire!(job)
        expect(job.reload.worker_id).to be_present
      end
    end

    context "when quota is full" do
      before do
        create_list(:job, 2, :running, client_id: client.client_id)
      end

      it "raises QuotaExceeded" do
        job = create(:job, client_id: client.client_id)
        expect { guard.acquire!(job) }.to raise_error(ConcurrencyGuard::QuotaExceeded)
      end

      it "does not change job state" do
        job = create(:job, client_id: client.client_id)
        guard.acquire!(job) rescue nil
        expect(job.reload.state).to eq("queued")
      end
    end

    context "when quota is dynamically reduced" do
      it "respects the new lower limit immediately" do
        # Start with limit=3, create 2 running jobs
        client.update!(concurrency_limit: 3)
        create_list(:job, 2, :running, client_id: client.client_id)

        # Reduce quota to 2 — now at capacity
        client.update!(concurrency_limit: 2)

        job = create(:job, client_id: client.client_id)
        expect { guard.acquire!(job) }.to raise_error(ConcurrencyGuard::QuotaExceeded)
      end
    end

    context "when the lock cannot be acquired" do
      let(:fake_lock_manager) do
        instance_double(Redlock::Client).tap do |lm|
          allow(lm).to receive(:lock).and_return(false)
          allow(lm).to receive(:unlock)
        end
      end

      it "raises LockTimeout" do
        job = create(:job, client_id: client.client_id)
        expect { guard.acquire!(job) }.to raise_error(ConcurrencyGuard::LockTimeout)
      end
    end

    context "when the job was already claimed (race condition)" do
      it "returns false without raising" do
        job = create(:job, :running, client_id: client.client_id)
        # Job is already running — FOR UPDATE SKIP LOCKED returns nil
        result = guard.acquire!(job)
        expect(result).to be false
      end
    end

    context "concurrent acquisition attempts" do
      it "grants the slot to exactly one of two concurrent callers" do
        client = create(:client, concurrency_limit: 1)
        job    = create(:job, client_id: client.client_id)

        results = []
        errors  = []

        # Use real DB transactions; simulate two threads competing
        threads = 2.times.map do
          Thread.new do
            g = described_class.new(lock_manager: fake_lock_manager)
            begin
              results << g.acquire!(job)
            rescue => e
              errors << e
            end
          end
        end
        threads.each(&:join)

        # One succeeded, one failed (either false or exception)
        successes = results.count(true)
        expect(successes).to eq(1)
        expect(Job.where(client_id: client.client_id, state: "running").count).to eq(1)
      end
    end
  end

  describe "#slots_in_use" do
    it "returns the count of running jobs for a client" do
      create_list(:job, 3, :running, client_id: client.client_id)
      create(:job, :completed, client_id: client.client_id)

      expect(guard.slots_in_use(client.client_id)).to eq(3)
    end
  end

  describe "#quota_for" do
    it "returns the client's concurrency_limit from the DB" do
      expect(guard.quota_for(client.client_id)).to eq(2)
    end

    it "returns 5 when client does not exist" do
      expect(guard.quota_for("nonexistent")).to eq(5)
    end
  end
end