# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/echo_release_delivery"

class ReleaseDeliveryTest < Minitest::Test
  def with_plan(ios:, macos:)
    prior = ENV["RELEASE_PLAN"]
    ENV["RELEASE_PLAN"] = JSON.generate(platforms: {ios: {build: ios}, macos: {build: macos}})
    yield
  ensure
    ENV["RELEASE_PLAN"] = prior
  end

  def test_selective_mac_retry_does_not_request_ios
    with_plan(ios: false, macos: true) do
      refute EchoReleaseDelivery.requested?("ios")
      assert EchoReleaseDelivery.requested?("macos")
    end
  end

  def test_selective_ios_retry_does_not_request_mac
    with_plan(ios: true, macos: false) do
      assert EchoReleaseDelivery.requested?("ios")
      refute EchoReleaseDelivery.requested?("macos")
    end
  end

  def test_local_calls_still_build_both_platforms
    prior = ENV.delete("RELEASE_PLAN")
    assert EchoReleaseDelivery.requested?("ios")
    assert EchoReleaseDelivery.requested?("macos")
  ensure
    ENV["RELEASE_PLAN"] = prior
  end

  def test_malformed_plan_fails_closed
    prior = ENV["RELEASE_PLAN"]
    ENV["RELEASE_PLAN"] = "invalid"
    assert_raises(JSON::ParserError) { EchoReleaseDelivery.requested?("ios") }
  ensure
    ENV["RELEASE_PLAN"] = prior
  end
end
