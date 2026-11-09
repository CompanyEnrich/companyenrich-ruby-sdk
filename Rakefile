# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "test" << "lib"
  task.pattern = "test/**/*_test.rb"
end

begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new(:lint)
rescue LoadError
  # RuboCop is skipped in the test matrix, where only the test task runs.
end

task default: %i[test lint]
