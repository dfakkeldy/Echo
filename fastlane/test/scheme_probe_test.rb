# frozen_string_literal: true

repository_root = File.expand_path("../..", __dir__)

# Load the real Fastfile while deliberately not registering or executing lanes.
# The two top-level DSL calls are all that need stubbing before the platform
# blocks; `platform` does not yield, so no signing or App Store action can run.
def default_platform(*) end
def platform(*) end

load File.join(repository_root, "fastlane", "Fastfile")

failures = []

[
  repository_root,
  File.join(repository_root, "fastlane"),
].each do |working_directory|
  Dir.chdir(working_directory) do
    unless scheme_exists?("Echo macOS")
      failures << "Echo macOS was not detected from #{working_directory}"
    end
  end
end

if scheme_exists?("Echo macOS Missing")
  failures << "a missing shared scheme was reported as present"
end

abort(failures.join("\n")) unless failures.empty?

puts "Fastlane scheme probe passed from repository and fastlane working directories."
