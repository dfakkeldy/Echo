# frozen_string_literal: true

repository_root = File.expand_path("../..", __dir__)

# Load the real Fastfile without registering or executing lanes.
def default_platform(*) end
def platform(*) end

load File.join(repository_root, "fastlane", "Fastfile")

review_info = {
  contact_email: "beta@example.com",
  contact_first_name: "Beta",
  contact_last_name: "Reviewer",
  contact_phone: "+1 555 0100",
  demo_account_required: false,
  notes: "Open the included sample book."
}.freeze

internal_options = testflight_distribution_options(
  group: "Nightly",
  external: false,
  review_info: nil
)

expected_internal_options = {
  notify_external_testers: false
}

external_options = testflight_distribution_options(
  group: "Weekly",
  external: true,
  review_info: review_info
)

expected_external_options = {
  notify_external_testers: true,
  groups: ["Weekly"],
  distribute_external: true,
  submit_beta_review: true,
  beta_app_review_info: review_info,
  demo_account_required: false
}

failures = []
unless internal_options == expected_internal_options
  failures << "Nightly distribution options were #{internal_options.inspect}"
end
unless external_options == expected_external_options
  failures << "Weekly distribution options were #{external_options.inspect}"
end

abort(failures.join("\n")) unless failures.empty?

puts "Fastlane TestFlight distribution options passed for Nightly and Weekly."
