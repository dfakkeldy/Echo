# frozen_string_literal: true

require "json"

# Local Fastlane calls keep their existing all-platform behavior. CI receives
# the immutable plan from the controller's read-only delivery comparison.
module EchoReleaseDelivery
  def self.requested?(platform)
    return true if ENV["RELEASE_PLAN"].to_s.empty?

    JSON.parse(ENV.fetch("RELEASE_PLAN")).fetch("platforms").fetch(platform).fetch("build") == true
  end

  def self.record(platform)
    return if ENV["RELEASE_PLAN"].to_s.empty?

    script = ENV.fetch("RELEASE_CONTROL_SCRIPT")
    raise "Could not record successful #{platform} delivery" unless system("python3", script, "record", "--platform", platform)
  end
end
