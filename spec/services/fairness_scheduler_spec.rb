# spec/services/fairness_scheduler_spec.rb
require "rails_helper"

RSpec.describe FairnessScheduler do
  subject(:scheduler) { described_class.new }

  describe "#next_job" do
    context "with no runnable jobs" do
      it "returns nil" do
        expect(scheduler.next_job).to be_nil
      end
    end

    context "with a single runnable job" do
      it "returns that job" do
        job = create(:job)
        expect(scheduler.next_job).to eq(job)
      end
    end

    context "priority ordering within a single client" do
      it "returns the high priority job first" do
        client = create(:client)
        low    = create(:job, :low_priority,  client_id: client.client_id)
        high   = create(:job, :high_priority, client_id: client.client_id)
        medium = create(:job,                 client_id: client.client_id)

        expect(scheduler.next_job).to eq(high)
      end
    end

    context "fairness across clients — starvation prevention" do
      it "deprioritizes a client that has dispatched many jobs" do
        client_a = create(:client)
        client_b = create(:client)

        job_a1 = create(:job, :high_priority, client_id: client_a.client_id)
        job_a2 = create(:job, :high_priority, client_id: client_a.client_id)
        job_b1 = create(:job, :high_priority, client_id: client_b.client_id)

        # Simulate client_a having dispatched 5 jobs already
        5.times { scheduler.record_dispatch(job_a1) }

        # Now client_b should be selected even though both have high-priority jobs
        next_job = scheduler.next_job
        expect(next_job.client_id).to eq(client_b.client_id)
      end

      it "alternates between equal-VFT clients in a round-robin fashion" do
        clients = create_list(:client, 3)
        jobs = clients.map { |c| create(:job, :high_priority, client_id: c.client_id) }

        selected_clients = 3.times.map do
          j = scheduler.next_job
          scheduler.record_dispatch(j)
          j.client_id
        end

        # All three clients should have been selected once
        expect(selected_clients.uniq.sort).to eq(clients.map(&:client_id).sort)
      end
    end

    context "respecting run_at for retried jobs" do
      it "excludes jobs whose run_at is in the future" do
        future_job  = create(:job, run_at: 5.minutes.from_now)
        present_job = create(:job, run_at: nil)

        expect(scheduler.next_job).to eq(present_job)
      end
    end
  end

  describe "#record_dispatch" do
    it "increments the client VFT by 1/weight for the given priority" do
      client = create(:client)
      job    = create(:job, :high_priority, client_id: client.client_id)

      expect { scheduler.record_dispatch(job) }
        .to change { scheduler.vft_for(client.client_id) }
        .by(1.0 / Job::PRIORITY_WEIGHTS["high"])
    end

    it "increments more for low-priority jobs (discouraging abuse)" do
      client   = create(:client)
      high_job = create(:job, :high_priority, client_id: client.client_id)
      low_job  = create(:job, :low_priority,  client_id: client.client_id)

      scheduler.record_dispatch(high_job)
      vft_after_high = scheduler.vft_for(client.client_id)

      # Reset VFT
      scheduler.instance_variable_get(:@redis).del("vft:#{client.client_id}")

      scheduler.record_dispatch(low_job)
      vft_after_low = scheduler.vft_for(client.client_id)

      expect(vft_after_low).to be > vft_after_high
    end
  end
end