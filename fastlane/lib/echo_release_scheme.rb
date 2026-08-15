# frozen_string_literal: true

module EchoReleaseScheme
  REPOSITORY_ROOT = File.expand_path("../..", __dir__)

  def self.scheme_exists?(scheme_name)
    File.file?(
      File.join(
        REPOSITORY_ROOT,
        "Echo.xcodeproj",
        "xcshareddata",
        "xcschemes",
        "#{scheme_name}.xcscheme"
      )
    )
  end
end
