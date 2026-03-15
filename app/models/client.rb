class Client < ApplicationRecord
  has_many :jobs, foreign_key: :client_id, dependent: :restrict_with_error

  validates :client_id,          presence: true, uniqueness: true
  validates :concurrency_limit,  numericality: { greater_than: 0 }
  validates :limit_per_minute, numericality: { greater_than: 0 }

  # Return (or lazily create) the Client row for a given client_id string.
  # Using find_or_create_by! with default values ensures jobs can be submitted
  # even before an explicit client registration call.
  def self.find_or_provision!(client_id)
    client = self.find_or_initialize_by(client_id: client_id) 
    
    return client if client.persisted?
      client.attributes = { concurrency_limit: 50,
        limit_per_minute: 10
      }
      client.save!
      client
  rescue ActiveRecord::RecordNotUnique
    # Race condition on simultaneous first submission — retry once
    retry
  end
end