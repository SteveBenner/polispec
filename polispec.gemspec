# SPDX-License-Identifier: MIT

require "yaml"

manifest = YAML.safe_load(File.read(File.join(__dir__, "polispec.rplugin.yml")), permitted_classes: [], aliases: false)
description = manifest["description"].to_s

tracked = begin
  listing = IO.popen(["git", "ls-files", "-z"], chdir: __dir__, err: File::NULL, &:read)
  $?.success? && !listing.empty? ? listing.split("\0") : nil
rescue SystemCallError
  nil
end
tracked ||= Dir.chdir(__dir__) { Dir.glob("**/*", File::FNM_DOTMATCH).select { |path| File.file?(path) } }
skipped = %w[smoke.yml TOKENS.jsonl]
shipped = tracked.reject do |path|
  skipped.include?(path) || path.start_with?("assets/", "smoke/", ".specstory/")
end

Gem::Specification.new do |spec|
  spec.name = "polispec"
  spec.version = File.read(File.join(__dir__, "VERSION")).strip
  spec.summary = description
  spec.description = description
  spec.authors = ["Sven Benner"]
  spec.email = "developer@sensiblesolutions.me"
  spec.homepage = "https://github.com/SteveBenner/polispec"
  spec.metadata["source_code_uri"] = "https://github.com/SteveBenner/polispec"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.6"
  spec.files = shipped
  spec.bindir = "bin"
  spec.executables = ["polispec", "polispec-guard"]
  spec.require_paths = ["lib"]
end
