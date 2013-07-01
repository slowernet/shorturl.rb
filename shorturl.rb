require 'sinatra'
require 'sinatra/respond_with'
require 'redis'
require 'nest'
require 'json'

%w(./config/config.rb).each { |path| load path if Pathname.new(path).exist? }

# schema
# shorturl:u => { :url => :shortcode } (hash) (dictionary of all shortened URLs)
# shorturl:c:<shortcode> =>  { :url, :count } (hash)
# shorturl:a => [ [created_at_ms, url], ... ] (zset of all urls, scored by created_at_ms)

class Shorturl
	class Shortcode
		class InvalidError < RuntimeError; end
		
		def self.validate(shortcode)
			shortcode =~ $config[:app][:shortcode_format]
		end
		
		def self.generate(namespace)
			begin 
				shortcode = (1..$config[:app][:shortcode_length]).map { ['a'..'z', 0..9].map(&:to_a).flatten.sample }.join
			end until !(namespace[shortcode].exists)
			shortcode
		end
	end
	
	
	def self.absolutize(shortcode)
		URI.join("#{$config[:app][:shorturl_base]}", shortcode).to_s
	end
	
	def self.save(url, shortcode)
		$redis.redis.multi
		$redis['a'].zadd((Time.now.to_f * 1000).to_i, shortcode)
		$redis['c'][shortcode].hmset('url', url, 'count', 0)
		$redis['u'].hset(url, shortcode)
		$redis.redis.exec
	end
end

configure do
	use Rack::JSONP

	# disable :protection
	$redis = Nest.new($config[:redis][:namespace], Redis.new(:url => $config[:redis][:url]))
end

get '/' do
	links = $redis['a'].zrevrangebyscore("+inf", "-inf", :with_scores => true).map do |shortcode, created_at|
		c = $redis['c'][shortcode].hgetall
		{ 
			:url => c['url'],
			:shorturl => Shorturl.absolutize(shortcode), 
			:count => c['count'].to_i,
			:shortcode => shortcode, 
			:created_at => Time.at(created_at/1000.0).utc
		}
	end
	
	respond_to do |f|
		f.json { links.to_json }
	end
end

post '/' do
	halt 400, 'Malformed URL' unless params[:url] =~ URI::regexp
	
	if !params[:shortcode].nil? && !params[:shortcode].empty?	# desired shortcode passed in?
		halt 400, "Invalid shortcode (#{$config[:app][:shortcode_format].inspect})" unless Shorturl::Shortcode.validate(params[:shortcode])
		if $redis['c'][params[:shortcode]].exists && params[:url] != $redis['c'][params[:shortcode]].hget('url')	# passed shortcode in use elsewhere?
			halt 400, 'Shortcode in use'
		else
			shortcode = params[:shortcode]
			Shorturl.save(params[:url], shortcode)
		end
	elsif !(shortcode = $redis['u'].hget(params[:url]))	# url not yet shortened
		shortcode = Shorturl::Shortcode.generate($redis['c'])
		Shorturl.save(params[:url], shortcode)
	end

	url = Shorturl.absolutize(shortcode)
	
	respond_to do |f|
		f.json { url.to_json }
		f.txt { url }
	end
end

# "stats"
get %r{/([a-z0-9\-]+)\+} do |shortcode|
	respond_to do |f|
		f.json { { shortcode => $redis['c'][shortcode].hget('count') }.to_json }
	end
end

get %r{/([a-z0-9\-]+)} do |shortcode|
	$redis['c'][shortcode].hincrby('count', 1)
	redirect $redis['c'][shortcode].hget('url'), 307
end
