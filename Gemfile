source 'https://rubygems.org'

# Specify your gem's dependencies in message_bus.gemspec
gemspec

group :test do
  gem 'rspec'
  gem 'redis'
  gem 'rake'
  gem 'guard-rspec'
  gem 'rb-inotify', require: RUBY_PLATFORM =~ /linux/i ? 'rb-inotify' : false
  gem 'rack'
  gem 'http_parser.rb'
  gem 'rack-test', require: 'rack/test'
end
