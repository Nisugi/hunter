# frozen_string_literal: true

require_relative 'tools/build'

desc 'Build the single-file dist/eohunter.lic from the parts under scripts/eohunter/'
task :build do
  root = __dir__
  path = EOHunter::Build.write(root: root)
  puts "built #{path} (#{File.read(path).lines.size} lines), map at #{path}.map"
end

desc 'Remove dist/'
task :clean do
  require 'fileutils'
  FileUtils.rm_rf(File.join(__dir__, 'dist'))
end

task default: :build

begin
  require 'yard'
  YARD::Rake::YardocTask.new(:doc) do |t|
    t.options = [] # everything is in .yardopts
  end
  desc 'YARD coverage, listing what is undocumented'
  task 'doc:stats' do
    sh 'bundle exec yard stats --list-undoc'
  end
rescue LoadError
  desc 'YARD is not installed'
  task(:doc) { abort 'bundle install first: yard is missing' }
end
