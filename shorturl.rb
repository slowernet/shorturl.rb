require 'sinatra'
require 'sinatra/respond_with'
require 'redis'
require 'nest'
require 'json'

%w(./config/config.rb).each { |path| load path if Pathname.new(path).exist? }

# schema
# shorturl:u:<url> => shortcode (string)
# shorturl:c:<shortcode> =>  { :url, :count } (hash)
# shorturl:a => [ [created_at_ms, url], ... ] (zset of all links shortened, scored by created_at)

class Shorturl
	def self.shortcode
		(1..$config[:app][:shortcode_length]).map{ ['a'..'z', 0..9].map(&:to_a).flatten.sample }.join
	end
	
	def self.absolutize(shortcode)
		URI.join("#{$config[:app][:shorturl_base]}", shortcode).to_s
	end
end


configure do
	# disable :protection
	$redis = Nest.new($config[:redis][:namespace], Redis.new(:url => $config[:redis][:url]))
end

get '/' do
	links = $redis['a'].zrevrangebyscore("+inf", "-inf", :with_scores => true).map do |url, created_at|
		shortcode = $redis['u'][url].get
		{ 
			:url => url, 
			:shorturl => Shorturl.absolutize(shortcode), 
			:shortcode => shortcode, 
			:count => $redis['c'][shortcode].hget('count').to_i,
			:created_at => Time.at(created_at/1000.0).utc
		}
	end
	
	respond_to do |f|
		f.json { links.to_json }
	end
end

post '/' do
	halt 400 unless params[:url] =~ URI::regexp
	
	unless shortcode = $redis['u'][params[:url]].get
		shortcode = params[:shortcode].empty? ? (begin c = Shorturl.shortcode; end until !($redis['c'][c].exists); c) : params[:shortcode]
		$redis['a'].zadd((Time.now.to_f * 1000).to_i, params[:url])
		$redis['c'][shortcode].hmset('url', params[:url], 'count', 0)
		$redis['u'][params[:url]].set(shortcode)
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
		f.json { $redis['c'][shortcode].hget('count').to_json }
	end
end

get %r{/([a-z0-9\-]+)} do |shortcode|
	$redis['c'][shortcode].hincrby('count', 1)
	redirect $redis['c'][shortcode].hget('url'), 307
end
