FactoryBot.define do
  factory :job do
    association :client, strategy: :create
    client_id { client.client_id }
    priority  { "medium" }
    workload  { "fast_task" }
    state     { "queued" }
 
    # state_machines may reset the state column back to :initial on save.
    # We force the intended state via update_column (bypasses all callbacks)
    # after every create so factory traits like :failed, :stalled etc. work.
    after(:create) do |job|
      intended = job.read_attribute(:state)
      job.update_column(:state, intended)
      job.reload   # sync in-memory state machine with the DB column
    end
 
    trait :high_priority do
      priority { "high" }
    end
 
    trait :low_priority do
      priority { "low" }
    end
 
    # Write state directly via column assignment so FactoryBot bypasses
    # the state machine guard (we're seeding test data, not transitioning).
    trait :running do
      state             { "running" }
      started_at        { Time.current }
      last_heartbeat_at { Time.current }
    end
 
    trait :completed do
      state        { "completed" }
      started_at   { 1.minute.ago }
      completed_at { Time.current }
    end
 
    trait :failed do
      state         { "failed" }
      started_at    { 1.minute.ago }
      failed_at     { Time.current }
      error_message { "Something went wrong" }
    end
 
    trait :stalled do
      state             { "stalled" }
      started_at        { 5.minutes.ago }
      last_heartbeat_at { 5.minutes.ago }
      stalled_at        { Time.current }
    end
 
    trait :stale_heartbeat do
      state             { "running" }
      started_at        { 5.minutes.ago }
      last_heartbeat_at { 2.minutes.ago }
    end
 
    trait :retriable do
      state       { "failed" }
      failed_at   { 1.minute.ago }
      retry_count { 1 }
      max_retries { 3 }
    end
 
    trait :exhausted do
      state       { "failed" }
      failed_at   { 1.minute.ago }
      retry_count { 3 }
      max_retries { 3 }
    end
  end
end
