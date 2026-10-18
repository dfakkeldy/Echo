require 'xcodeproj'
p = Xcodeproj::Project.open('Echo.xcodeproj')
cli = p.targets.find { |t| t.name == 'echo-cli' } or abort 'no echo-cli'

ap = p.root_object.package_references.find { |r| (r.repositoryURL rescue '').to_s.include?('swift-argument-parser') }
unless ap
  ap = p.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  ap.repositoryURL = 'https://github.com/apple/swift-argument-parser'
  ap.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => '1.0.0' }
  p.root_object.package_references << ap
  puts 'added swift-argument-parser package reference'
end
unless cli.package_product_dependencies.any? { |d| d.product_name == 'ArgumentParser' }
  dep = p.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.product_name = 'ArgumentParser'; dep.package = ap
  cli.package_product_dependencies << dep
  bf = p.new(Xcodeproj::Project::Object::PBXBuildFile); bf.product_ref = dep
  cli.frameworks_build_phase.files << bf
  puts 'linked ArgumentParser to echo-cli'
end
unless p.objects.any? { |o| o.isa == 'PBXFileReference' && o.path == 'Tools/echo-cli/NarrateCommand.swift' }
  r = p.new(Xcodeproj::Project::Object::PBXFileReference)
  r.last_known_file_type = 'sourcecode.swift'; r.path = 'Tools/echo-cli/NarrateCommand.swift'
  r.name = 'NarrateCommand.swift'; r.source_tree = 'SOURCE_ROOT'
  p.main_group << r
  cli.source_build_phase.add_file_reference(r)
  puts 'added NarrateCommand.swift source'
end
p.save
