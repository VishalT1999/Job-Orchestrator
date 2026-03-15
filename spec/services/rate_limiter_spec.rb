# spec/services/rate_limiter_spec.rb
require "rails_helper"

RSpec.describe RateLimiter do
  subject(:limiter) { described_class.new }

  describe "#check!" do
    let(:client_id) { "test_client" }

    context "within rate limit" do
      before { create(:client, client_id: client_id, limit_per_minute: 5) }

      it "does not raise for the first request" do
        expect { limiter.check!(client_id) }.not_to raise_error
      end

      it "does not raise when at the limit boundary" do
        4.times { limiter.check!(client_id) }
        expect { limiter.check!(client_id) }.not_to raise_error
      end
    end

    context "exceeding rate limit" do
      before { create(:client, client_id: client_id, limit_per_minute: 3) }

      it "raises RateLimitExceeded on the 4th request" do
        3.times { limiter.check!(client_id) }
        expect { limiter.check!(client_id) }.to raise_error(RateLimiter::RateLimitExceeded)
      end

      it "includes retry_after in the exception" do
        3.times { limiter.check!(client_id) }
        begin
          limiter.check!(client_id)
        rescue RateLimiter::RateLimitExceeded => e
          expect(e.retry_after).to be_positive
        end
      end
    end

    context "for unknown clients" do
      it "defaults to 100 requests per minute" do
        99.times { limiter.check!("unknown_client") }
        expect { limiter.check!("unknown_client") }.not_to raise_error
      end
    end

    context "sliding window" do
      before { create(:client, client_id: client_id, limit_per_minute: 2) }

      it "allows requests again after the window slides" do
        Timecop.freeze(Time.current) do
          2.times { limiter.check!(client_id) }
          expect { limiter.check!(client_id) }.to raise_error(RateLimiter::RateLimitExceeded)

          # Slide the window forward by 61 seconds
          Timecop.travel(61.seconds.from_now)
          expect { limiter.check!(client_id) }.not_to raise_error
        end
      end
    end
  end
end