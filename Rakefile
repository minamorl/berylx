# frozen_string_literal: true

require 'rake/testtask'
require 'rubocop/rake_task'

Rake::TestTask.new(:test) do |task|
  task.libs << 'test'
  task.pattern = 'test/**/*_test.rb'
end

RuboCop::RakeTask.new(:rubocop)

desc 'Compile the berylx_native C extension into lib/berylx_native'
task :compile do
  ext_dir = File.expand_path('ext/berylx_native', __dir__)
  lib_dir = File.expand_path('lib/berylx_native', __dir__)
  Dir.chdir(ext_dir) do
    ruby 'extconf.rb'
    sh 'make'
  end
  mkdir_p lib_dir
  cp File.join(ext_dir, "berylx_native.#{RbConfig::CONFIG['DLEXT']}"), lib_dir
end

task lint: :rubocop
task default: %i[test rubocop]
