# frozen_string_literal: true

require_relative "lib/companyenrich/version"

Gem::Specification.new do |spec|
  spec.name = "companyenrich"
  spec.version = CompanyEnrich::VERSION
  spec.authors = ["CompanyEnrich"]
  spec.email = ["support@companyenrich.com"]
  spec.summary = "Official Ruby SDK for the CompanyEnrich API."
  spec.description = "Company and people enrichment, filter, semantic and lookalike search, work emails, " \
                     "and bulk jobs through the CompanyEnrich API."
  spec.homepage = "https://github.com/CompanyEnrich/companyenrich-ruby-sdk"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.metadata = {
    "homepage_uri" => "https://companyenrich.com",
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
end
