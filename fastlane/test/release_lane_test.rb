# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"

LANES = {}
EVENTS = []
CONTEXT = {}
module SharedValues
  MATCH_PROVISIONING_PROFILE_MAPPING = :profiles
  PKG_OUTPUT_PATH = :pkg
  IPA_OUTPUT_PATH = :ipa
end
module UI
  def self.message(*) end
  def self.important(*) end
  def self.user_error!(message) = raise(message)
end

def default_platform(*) end
def platform(*) = yield
def before_all(*) end
def desc(*) end
def lane(name, &block) = LANES[name] = block

load File.expand_path("../Fastfile", __dir__)

def require_api_key! = EVENTS << :required_gate
def is_ci = false
def sh(*) end
def scheme_exists?(*) = true
def lane_context = CONTEXT
def sync_code_signing(*) = EVENTS << :signing_gate
def github_warning(*) = EVENTS << :warning
def mac_installer_identity_missing? = false

def latest_testflight_build_number(platform:, **)
  EVENTS << [:counter, platform]
  platform == "ios" ? 120 : 125
end

def build_app(scheme:, xcargs:, **)
  EVENTS << [:build, scheme, xcargs]
  raise "simulated Mac archive failure" if scheme == "Echo macOS" && $failure == :mac_archive
  CONTEXT[SharedValues::PKG_OUTPUT_PATH] = $pkg_path if scheme == "Echo macOS"
end

def upload_to_testflight(options)
  platform = options.fetch(:app_platform)
  EVENTS << [:upload, platform]
  raise "simulated upload failure" if $failure == platform
end

class ReleaseLaneTest < Minitest::Test
  def setup
    EVENTS.clear
    CONTEXT.clear
    @old_plan = ENV["RELEASE_PLAN"]
    $failure = nil
    @pkg = Tempfile.new(["echo-release-test", ".pkg"])
    $pkg_path = @pkg.path
  end

  def teardown
    ENV["RELEASE_PLAN"] = @old_plan
    @pkg.close!
  end

  def beta(ios:, macos:)
    ENV["RELEASE_PLAN"] = JSON.generate(platforms: {ios: {build: ios}, macos: {build: macos}})
    original_record = EchoReleaseDelivery.method(:record)
    EchoReleaseDelivery.define_singleton_method(:record) { |platform| EVENTS << [:receipt, platform] }
    Dir.chdir(File.expand_path("..", __dir__)) { LANES.fetch(:beta).call(channel: "nightly") }
  ensure
    EchoReleaseDelivery.define_singleton_method(:record, original_record)
  end

  def test_mac_only_retry_skips_ios_archive_and_upload_and_uses_mac_counter
    beta(ios: false, macos: true)
    assert_equal ["Echo macOS"], EVENTS.filter_map { |e| e[1] if e.is_a?(Array) && e[0] == :build }
    assert_includes EVENTS, [:upload, "osx"]
    refute_includes EVENTS, [:upload, "ios"]
    assert_includes EVENTS, [:receipt, "macos"]
    assert EVENTS.any? { |e| e.is_a?(Array) && e[0] == :build && e[2].include?("CURRENT_PROJECT_VERSION=126") }
  end

  def test_ios_only_retry_skips_mac_archive_and_upload
    beta(ios: true, macos: false)
    assert_includes EVENTS, [:upload, "ios"]
    refute_includes EVENTS, [:upload, "osx"]
    assert_includes EVENTS, [:receipt, "ios"]
    refute_includes EVENTS, [:receipt, "macos"]
  end

  def test_mac_archive_failure_cannot_emit_mac_receipt
    $failure = :mac_archive
    beta(ios: true, macos: true)
    assert_includes EVENTS, [:receipt, "ios"]
    refute_includes EVENTS, [:receipt, "macos"]
  end

  def test_mac_upload_failure_cannot_emit_mac_receipt
    $failure = "osx"
    beta(ios: true, macos: true)
    assert_includes EVENTS, [:receipt, "ios"]
    refute_includes EVENTS, [:receipt, "macos"]
  end

  def test_failed_ios_delivery_cannot_emit_receipt
    $failure = "ios"
    assert_raises(RuntimeError) { beta(ios: true, macos: false) }
    refute EVENTS.any? { |e| e.is_a?(Array) && e[0] == :receipt }
  end

  def test_requested_rebuild_still_executes_gates_before_receipt
    beta(ios: true, macos: true)
    assert_equal :required_gate, EVENTS.first
    assert_operator EVENTS.index(:signing_gate), :<, EVENTS.index([:upload, "ios"])
    assert_operator EVENTS.index([:upload, "ios"]), :<, EVENTS.index([:receipt, "ios"])
    assert_operator EVENTS.index([:upload, "osx"]), :<, EVENTS.index([:receipt, "macos"])
  end
end
