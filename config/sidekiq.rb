Sidekiq.configure_server do |config|
  config.on(:startup) do
    schedule_file = Rails.root.join("config", "schedule.yml")
    Sidekiq::Scheduler.reload_schedule! if File.exist?(schedule_file)
  end
end