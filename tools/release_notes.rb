# frozen_string_literal: true

version, path = ARGV
path ||= "CHANGELOG.md"
abort "Usage: ruby tools/release_notes.rb VERSION [CHANGELOG]" unless version

lines = File.readlines(path)
start = lines.index { |line| line.match?(/\A## #{Regexp.escape(version)}(?:\s|\z)/) }
abort "No changelog entry for #{version}" unless start

notes = lines.drop(start + 1).take_while { |line| !line.start_with?("## ") }.join.strip
abort "Empty changelog entry for #{version}" if notes.empty?

puts notes
