# Adds the `echo-cli` macOS command-line-tool target to Echo.xcodeproj.
# Run with: RUBYOPT='-E UTF-8:UTF-8' ruby Tools/echo-cli/add-target.rb
require 'xcodeproj'

proj = Xcodeproj::Project.open('Echo.xcodeproj')
abort 'echo-cli already exists' if proj.targets.any? { |t| t.name == 'echo-cli' }

mac = proj.targets.find { |t| t.name == 'Echo macOS' } or abort 'no Echo macOS target'

# 1. The tool target.
t = proj.new_target(:command_line_tool, 'echo-cli', :osx, '15.0')

# 2. Build settings (model on Echo macOS; ad-hoc sign; no sandbox).
t.build_configurations.each do |c|
  bs = c.build_settings
  bs['PRODUCT_NAME'] = 'echo-cli'
  bs['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.echo.audiobooks.cli'
  bs['SWIFT_VERSION'] = '6.0'
  bs['MACOSX_DEPLOYMENT_TARGET'] = '15.0'
  bs['SDKROOT'] = 'macosx'
  bs['CODE_SIGN_STYLE'] = 'Manual'
  bs['CODE_SIGN_IDENTITY'] = '-'
  bs['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  bs['SWIFT_OBJC_INTEROP_MODE'] = 'objcxx'
end

# 3. Compile EchoCore + Shared into the tool (the synchronized groups the app uses).
ec = proj.objects.find { |o| o.isa == 'PBXFileSystemSynchronizedRootGroup' && o.path == 'EchoCore' }
sh = proj.objects.find { |o| o.isa == 'PBXFileSystemSynchronizedRootGroup' && o.path == 'Shared' }
abort 'missing EchoCore/Shared sync group' unless ec && sh
t.file_system_synchronized_groups << ec
t.file_system_synchronized_groups << sh

# 4. Link the SPM products the narration path needs (reuse the macOS target's
#    package references). NOT WhisperKit (alignment is Phase 2). ArgumentParser
#    is added in Task 4.
wanted = %w[GRDB ZIPFoundation MisakiSwift onnxruntime AudioMarker]
mac.package_product_dependencies.each do |src|
  next unless wanted.include?(src.product_name)
  dep = proj.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.product_name = src.product_name
  dep.package = src.package
  t.package_product_dependencies << dep
  bf = proj.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = dep
  t.frameworks_build_phase.files << bf
end

# 5. main.swift source.
main_ref = proj.new(Xcodeproj::Project::Object::PBXFileReference)
main_ref.last_known_file_type = 'sourcecode.swift'
main_ref.path = 'Tools/echo-cli/main.swift'
main_ref.name = 'main.swift'
main_ref.source_tree = 'SOURCE_ROOT'
proj.main_group << main_ref
t.source_build_phase.add_file_reference(main_ref)

# 6. Copy the bundled narration resources next to the binary so Bundle.main
#    (and the ECHO_RESOURCE_DIR default) can find them.
copy = t.new_copy_files_build_phase('Copy Narration Resources')
copy.symbol_dst_subfolder_spec = :products_directory
copy.dst_path = 'EchoNarrationResources'
[
  'EchoCore/Services/Narration/_kokoro_vocab.json',
  'EchoCore/Services/Narration/MisakiResources/us_gold.json',
  'EchoCore/Services/Narration/MisakiResources/us_silver.json',
  'EchoCore/Resources/af_heart.f32',
  'EchoCore/Resources/af_heart.rows',
].each do |rel|
  ref = proj.new(Xcodeproj::Project::Object::PBXFileReference)
  ref.path = rel
  ref.name = File.basename(rel)
  ref.source_tree = 'SOURCE_ROOT'
  proj.main_group << ref
  copy.add_file_reference(ref)
end

proj.save
puts "OK — added echo-cli target"
puts "  sync groups: #{t.file_system_synchronized_groups.map(&:path).inspect}"
puts "  pkg products: #{t.package_product_dependencies.map(&:product_name).inspect}"
puts "  phases: #{t.build_phases.map(&:display_name).inspect}"
