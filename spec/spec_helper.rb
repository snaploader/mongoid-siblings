require "rubygems"
require "bundler/setup"

require "mongoid"
require "mongoid/siblings"

require "rspec"

Mongoid.configure do |config|
  config.connect_to "mongoid_siblings_test"
end

Dir["#{File.dirname(__FILE__)}/support/**/*.rb"].each { |f| require f }

RSpec.configure do |config|
  config.after :each do
    Mongoid::Config.purge!
  end
end
