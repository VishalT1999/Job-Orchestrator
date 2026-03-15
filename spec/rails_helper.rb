# spec/rails_helper.rb
# require "spec_helper"
ENV["RAILS_ENV"] ||= "test"

require File.expand_path("../config/environment", __dir__)
abort("The Rails environment is running in production mode!") if Rails.env.production?

require "rspec/rails"
require "sidekiq/testing"
require "sidekiq/api"   # provides Sidekiq::Stats, Sidekiq::Queue
require "mock_redis"
require "timecop"

# Raise if test schema is out of sync with migrations — gives a clear error
# instead of the cryptic "Could not find table" message.
ActiveRecord::Migration.maintain_test_schema!

# Sidekiq fake mode — jobs are enqueued but not executed unless Sidekiq::Testing.inline!
Sidekiq::Testing.fake!

Dir[Rails.root.join("spec/support/**/*.rb")].sort.each { |f| require f }

# ---------------------------------------------------------------------------
# freeze_time helper — wraps Timecop.freeze so specs can write:
#
#   freeze_time do
#     job.start!
#     expect(job.started_at).to eq(Time.current)
#   end
#
# Also supports travel_to for relative time movement inside a block:
#
#   travel_to(1.hour.from_now) { expect(job).to be_stalled }
#
module TimeHelpers
  def freeze_time(&block)
    Timecop.freeze(Time.current, &block)
  end

  def travel_to(time, &block)
    Timecop.freeze(time, &block)
  end
end

RSpec.configure do |config|
  config.fixture_paths = [Rails.root.join("spec/fixtures")]
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include FactoryBot::Syntax::Methods
  config.include TimeHelpers                                        # freeze_time / travel_to
  config.include Shoulda::Matchers::ActiveRecord, type: :model
  config.include Shoulda::Matchers::ActiveModel,  type: :model

  # Stub Redis with a fresh MockRedis instance for every example so
  # state never leaks between tests.
  config.before(:each) do
    mock_redis = MockRedis.new
    allow(RedisPool).to receive(:instance).and_return(mock_redis)
  end

  # Always reset Timecop after each example so a frozen test cannot
  # affect the next one.
  config.after(:each) do
    Timecop.return
  end

  config.before(:suite) do
    DatabaseCleaner.strategy = :transaction
    DatabaseCleaner.clean_with(:truncation)
  end

  config.around(:each) do |example|
    DatabaseCleaner.cleaning { example.run }
  end
end

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end