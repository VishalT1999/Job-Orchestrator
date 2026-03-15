# spec/workers/job_dispatcher_worker_spec.rb
require "rails_helper"

RSpec.describe JobDispatcherWorker, type: :worker do
  subject(:worker) { described_class.new }

  let(:fake_lock_manager) do
    instance_double(Redlock::Client).tap do |lm|
      allow(lm).to receive(:lock).and_return({ validity: 5000, resource: "k", value: "v" })
      allow(lm).to receive(:unlock)
    end
  end

  before do
    allow(ConcurrencyGuard).to receive(:new).and_return(
      ConcurrencyGuard.new(lock_manager: fake_lock_manager)
    )
  end

  describe "#perform" do
    context "with runnable jobs" do
      let!(:client) { create(:client, concurrency_limit: 5) }
      let!(:jobs)   { create_list(:job, 3, client_id: client.client_id) }

      it "dispatches runnable jobs to JobExecutorWorker" do
        expect {
          worker.perform
        }.to change(JobExecutorWorker.jobs, :size).by(3)
      end

      it "transitions jobs to running state" do
        worker.perform
        jobs.each { |j| expect(j.reload.state).to eq("running") }
      end
    end

    context "with no runnable jobs" do
      it "does not enqueue any executor workers" do
        expect {
          worker.perform
        }.not_to change(JobExecutorWorker.jobs, :size)
      end
    end

    context "when client quota is full" do
      let!(:client) { create(:client, concurrency_limit: 1) }

      before do
        create(:job, :running, client_id: client.client_id)
      end

      it "does not dispatch additional jobs beyond the quota" do
        create(:job, client_id: client.client_id)

        worker.perform
        expect(Job.where(client_id: client.client_id, state: "running").count).to eq(1)
      end
    end

    context "priority ordering" do
      let!(:client) { create(:client, concurrency_limit: 1) }
      let!(:low)    { create(:job, :low_priority,  client_id: client.client_id) }
      let!(:high)   { create(:job, :high_priority, client_id: client.client_id) }

      it "dispatches the high priority job first" do
        worker.perform

        dispatched_id = JobExecutorWorker.jobs.first["args"].first
        expect(dispatched_id).to eq(high.id)
      end
    end
  end
end

# spec/workers/retry_job_worker_spec.rb
RSpec.describe RetryJobWorker, type: :worker do
  subject(:worker) { described_class.new }

  describe "#perform" do
    context "with a failed retriable job" do
      let!(:job) { create(:job, :retriable) }

      it "transitions the job to queued" do
        expect { worker.perform(job.id) }.to change { job.reload.state }.to("queued")
      end

      it "kicks JobDispatcherWorker to process the requeued job promptly" do
        expect { worker.perform(job.id) }.to change(JobDispatcherWorker.jobs, :size).by(1)
      end
    end

    context "with an exhausted job" do
      let!(:job) { create(:job, :exhausted) }

      it "does not change the job state" do
        worker.perform(job.id)
        expect(job.reload.state).to eq("failed")
      end

      it "does not kick the dispatcher" do
        expect { worker.perform(job.id) }.not_to change(RetryJobWorker.jobs, :size)
      end
    end

    context "when job is already queued (idempotency)" do
      let!(:job) { create(:job) }

      it "does not raise an error" do
        expect { worker.perform(job.id) }.not_to raise_error
      end

      it "leaves the job as queued" do
        worker.perform(job.id)
        expect(job.reload.state).to eq("queued")
      end
    end

    context "when job does not exist" do
      it "returns without raising" do
        expect { worker.perform(999_999) }.not_to raise_error
      end
    end
  end
end

# spec/workers/heartbeat_monitor_worker_spec.rb
RSpec.describe HeartbeatMonitorWorker, type: :worker do
  subject(:worker) { described_class.new }

  describe "#perform" do
    it "calls HeartbeatService#detect_and_stall_jobs" do
      svc = instance_double(HeartbeatService, detect_and_stall_jobs: 0)
      allow(HeartbeatService).to receive(:new).and_return(svc)

      worker.perform

      expect(svc).to have_received(:detect_and_stall_jobs)
    end

    it "stalls all stale-heartbeat jobs" do
      stale = create(:job, :stale_heartbeat)
      fresh = create(:job, :running, last_heartbeat_at: 5.seconds.ago)

      worker.perform

      expect(stale.reload.state).to eq("stalled")
      expect(fresh.reload.state).to eq("running")
    end
  end
end