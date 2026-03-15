# spec/models/job_spec.rb
require "rails_helper"

RSpec.describe Job, type: :model do
  # ---------------------------------------------------------------------------
  # Validations
  # ---------------------------------------------------------------------------
  describe "validations" do
    subject { build(:job) }

    it { is_expected.to validate_presence_of(:client_id) }
    it { is_expected.to validate_presence_of(:workload) }
    it { is_expected.to validate_inclusion_of(:priority).in_array(%w[low medium high]) }
  end

  # ---------------------------------------------------------------------------
  # State machine — happy path transitions
  # ---------------------------------------------------------------------------
  describe "state machine" do
    describe "initial state" do
      it "starts as queued" do
        job = build(:job)
        expect(job.state).to eq("queued")
        expect(job).to be_queued
      end

      it "exposes state predicates" do
        job = build(:job)
        expect(job.queued?).to    be true
        expect(job.running?).to   be false
        expect(job.completed?).to be false
      end
    end

    describe "queued → running (start!)" do
      it "transitions when quota is available" do
        client = create(:client, concurrency_limit: 5)
        job    = create(:job, client_id: client.client_id)
        expect { job.start! }.to change { job.state }.from("queued").to("running")
      end

      it "stamps started_at and last_heartbeat_at" do
        freeze_time do
          job = create(:job)
          job.start!
          expect(job.started_at).to       eq(Time.current)
          expect(job.last_heartbeat_at).to eq(Time.current)
        end
      end

      it "returns true on success" do
        expect(create(:job).start!).to be true
      end
    end

    describe "running → completed (complete!)" do
      it "transitions and stamps completed_at" do
        freeze_time do
          job = create(:job, :running)
          job.complete!
          expect(job.state).to        eq("completed")
          expect(job.completed_at).to eq(Time.current)
        end
      end
    end

    describe "running → failed (mark_failed!)" do
      it "transitions and stamps failed_at" do
        freeze_time do
          job = create(:job, :running)
          job.mark_failed!
          expect(job.state).to    eq("failed")
          expect(job.failed_at).to eq(Time.current)
        end
      end
    end

    describe "running → stalled (stall!)" do
      it "transitions and stamps stalled_at" do
        freeze_time do
          job = create(:job, :running)
          job.stall!
          expect(job.state).to     eq("stalled")
          expect(job.stalled_at).to eq(Time.current)
        end
      end
    end

    describe "failed|stalled → queued (requeue!)" do
      it "transitions from failed when retries remain" do
        job = create(:job, :retriable)
        expect { job.requeue! }.to change { job.state }.from("failed").to("queued")
      end

      it "transitions from stalled when retries remain" do
        job = create(:job, :stalled, retry_count: 0, max_retries: 3)
        expect { job.requeue! }.to change { job.state }.from("stalled").to("queued")
      end

      it "increments retry_count" do
        job = create(:job, :retriable, retry_count: 1)
        expect { job.requeue! }.to change { job.retry_count }.by(1)
      end

      it "sets run_at for exponential backoff" do
        job = create(:job, :retriable, retry_count: 1)
        freeze_time do
          job.requeue!
          expect(job.run_at).to be_within(1.second).of(60.seconds.from_now)
        end
      end

      it "clears error_message and worker_id" do
        job = create(:job, :failed, error_message: "boom", worker_id: "host:123")
        job.requeue!
        expect(job.error_message).to be_nil
        expect(job.worker_id).to     be_nil
      end

      it "raises StateMachines::InvalidTransition when retries exhausted" do
        job = create(:job, :exhausted)
        expect { job.requeue! }.to raise_error(StateMachines::InvalidTransition)
        expect(job.state).to eq("failed")
      end

      it "non-bang requeue returns false when exhausted" do
        job = create(:job, :exhausted)
        expect(job.requeue).to be false
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Illegal transitions
  # ---------------------------------------------------------------------------
  describe "illegal transitions" do
    {
      "queued → completed"  => [:queued,    :complete!],
      "queued → failed"     => [:queued,    :mark_failed!],
      "queued → stalled"    => [:queued,    :stall!],
      "completed → running" => [:completed, :start!],
      "completed → failed"  => [:completed, :mark_failed!],
      "failed → running"    => [:failed,    :start!],
    }.each do |label, (trait_or_default, event)|
      it "cannot transition #{label}" do
        # :queued is the default state — no factory trait exists for it
        job = trait_or_default == :queued ? create(:job) : create(:job, trait_or_default)
        expect { job.public_send(event) }.to raise_error(StateMachines::InvalidTransition)
      end
    end

    it "non-bang method returns false instead of raising" do
      job = create(:job)
      expect(job.complete).to be false
      expect(job.state).to     eq("queued")
    end
  end

  # ---------------------------------------------------------------------------
  # Concurrency quota guard (if: on start event)
  # ---------------------------------------------------------------------------
  describe "concurrency quota guard" do
    it "rejects start! when quota is full" do
      client = create(:client, concurrency_limit: 2)
      create_list(:job, 2, :running, client_id: client.client_id)

      new_job = create(:job, client_id: client.client_id)
      expect { new_job.start! }.to raise_error(StateMachines::InvalidTransition)
    end

    it "permits start! when quota has space" do
      client = create(:client, concurrency_limit: 3)
      create(:job, :running, client_id: client.client_id)

      new_job = create(:job, client_id: client.client_id)
      expect { new_job.start! }.not_to raise_error
      expect(new_job).to be_running
    end
  end

  # ---------------------------------------------------------------------------
  # Optimistic locking
  # ---------------------------------------------------------------------------
  describe "optimistic locking" do
    it "raises StaleObjectError when two processes transition the same job" do
      job    = create(:job)
      copy_1 = Job.find(job.id)
      copy_2 = Job.find(job.id)

      copy_1.start!
      expect { copy_2.start! }.to raise_error(ActiveRecord::StaleObjectError)
    end

    it "leaves the job in a consistent state — only one transition commits" do
      job    = create(:job)
      copy_1 = Job.find(job.id)
      copy_2 = Job.find(job.id)

      copy_1.start!
      copy_2.start! rescue nil

      expect(job.reload.state).to eq("running")
      expect(Job.where(id: job.id, state: "running").count).to eq(1)
    end
  end

  # ---------------------------------------------------------------------------
  # Scopes
  # ---------------------------------------------------------------------------
  describe "scopes" do
    describe ".runnable" do
      it "includes queued jobs with no run_at"             do
        expect(Job.runnable).to include(create(:job, state: "queued", run_at: nil))
      end
      it "includes queued jobs whose run_at is past"       do
        expect(Job.runnable).to include(create(:job, state: "queued", run_at: 1.minute.ago))
      end
      it "excludes queued jobs whose run_at is future"     do
        expect(Job.runnable).not_to include(create(:job, state: "queued", run_at: 5.minutes.from_now))
      end
      it "excludes running jobs"                           do
        expect(Job.runnable).not_to include(create(:job, :running))
      end
    end

    describe ".stale_heartbeat" do
      it "includes running jobs silent for > 60s" do
        expect(Job.stale_heartbeat).to include(create(:job, :stale_heartbeat))
      end
      it "excludes recently-pulsed running jobs" do
        expect(Job.stale_heartbeat).not_to include(
          create(:job, :running, last_heartbeat_at: 10.seconds.ago)
        )
      end
      it "includes running jobs with nil last_heartbeat_at" do
        expect(Job.stale_heartbeat).to include(
          create(:job, state: "running", started_at: 2.minutes.ago, last_heartbeat_at: nil)
        )
      end
    end

    describe ".by_priority" do
      it "orders high → medium → low" do
        create(:job, :low_priority)
        create(:job, :high_priority)
        create(:job)
        expect(Job.by_priority.map(&:priority)).to eq(%w[high medium low])
      end

      it "breaks ties by created_at FIFO" do
        job1 = create(:job, :high_priority, created_at: 2.minutes.ago)
        job2 = create(:job, :high_priority, created_at: 1.minute.ago)
        expect(Job.by_priority.first).to eq(job1)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Audit logging callback
  # ---------------------------------------------------------------------------
  describe "transition audit logging" do
    it "logs every transition via the after_transition hook" do
      job = create(:job)
      expect(Rails.logger).to receive(:info).with(/queued → running/)
      job.start!
    end
  end

  # ---------------------------------------------------------------------------
  # Retry helpers
  # ---------------------------------------------------------------------------
  describe "#next_retry_delay" do
    it { expect(build(:job, retry_count: 0).next_retry_delay).to eq(30) }
    it { expect(build(:job, retry_count: 1).next_retry_delay).to eq(60) }
    it { expect(build(:job, retry_count: 2).next_retry_delay).to eq(120) }
    it { expect(build(:job, retry_count: 10).next_retry_delay).to eq(3600) }
  end

  describe "#retries_remaining?" do
    it { expect(build(:job, retry_count: 1, max_retries: 3).retries_remaining?).to be true }
    it { expect(build(:job, retry_count: 3, max_retries: 3).retries_remaining?).to be false }
  end
end