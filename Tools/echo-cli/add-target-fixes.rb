# Follow-up wiring for echo-cli: clone the macOS EchoCore membership exceptions
# (iOS-only/UI files), link WhisperKit (EchoCore's alignment files require it to
# compile), and create a shared scheme so SPM module maps are generated.
# Run with: RUBYOPT='-E UTF-8:UTF-8' ruby Tools/echo-cli/add-target-fixes.rb
require 'xcodeproj'

p = Xcodeproj::Project.open('Echo.xcodeproj')
cli = p.targets.find { |t| t.name == 'echo-cli' } or abort 'no echo-cli target'
mac = p.targets.find { |t| t.name == 'Echo macOS' } or abort 'no Echo macOS target'
ec  = p.objects.find { |o| o.isa == 'PBXFileSystemSynchronizedRootGroup' && o.path == 'EchoCore' }

# 1. Clone the macOS EchoCore exception set for echo-cli (exclude the same
#    iOS-only/UI files; the CLI compiles only the narration/alignment services).
unless ec.exceptions.any? { |ex| (ex.target == cli rescue false) }
  mac_ex = ec.exceptions.find { |ex| (ex.target == mac rescue false) } or abort 'no macOS exception set'
  files = mac_ex.membership_exceptions
  nex = p.new(Xcodeproj::Project::Object::PBXFileSystemSynchronizedBuildFileExceptionSet)
  nex.target = cli
  nex.membership_exceptions = files.dup
  ec.exceptions << nex
  puts "cloned #{files.size} EchoCore exclusions onto echo-cli"
end

# 2. Link WhisperKit (EchoCore's AutoAlignmentService/WhisperSession import it).
unless cli.package_product_dependencies.any? { |d| d.product_name == 'WhisperKit' }
  src = mac.package_product_dependencies.find { |d| d.product_name == 'WhisperKit' }
  dep = p.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.product_name = 'WhisperKit'
  dep.package = src.package
  cli.package_product_dependencies << dep
  bf = p.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = dep
  cli.frameworks_build_phase.files << bf
  puts 'linked WhisperKit'
end

p.save

# 3. Shared scheme (so `xcodebuild -scheme echo-cli` resolves + builds SPM
#    products and generates their module maps).
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(cli)
scheme.set_launch_target(cli) rescue nil
scheme.save_as(p.path, 'echo-cli', true)
puts 'wrote shared scheme echo-cli'

puts "pkg products now: #{cli.package_product_dependencies.map(&:product_name).inspect}"
