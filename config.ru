require 'bundler'
Bundler.require

require './shorturl'

run Rack::URLMap.new({ 
    "/" => Sinatra::Application
})