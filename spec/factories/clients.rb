FactoryBot.define do
  factory :client do
    sequence(:client_id) { |n| "client_#{n}" }
    concurrency_limit     { 5 }
    limit_per_minute { 100 }
  end
end
