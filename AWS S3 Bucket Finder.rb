#!/usr/bin/env ruby
require 'net/http'
require 'timeout'
require 'csv'
require 'json'

class String
  def red; "\e[31m#{self}\e[0m" end
  def green; "\e[32m#{self}\e[0m" end
end

class S3
  attr_reader :bucket, :domain, :code, :metadata

  def initialize(bucket)
    @bucket = bucket
    @domain = format('http://%s.s3.amazonaws.com', bucket)
  end

  def exists?
    code != 404
  end

  def code
    http && http.code.to_i
  end

  def metadata
    return @metadata if @metadata
    
    @metadata = {}
    if exists?
      # Add additional metadata extraction
      @metadata[:region] = extract_region
      @metadata[:public] = is_public?
      @metadata[:size] = calculate_size if has_objects?
    end
    @metadata
  end

  private

  def http
    Timeout::timeout(5) do
      @http ||= Net::HTTP.get_response(URI.parse(@domain))
    end
  rescue
  end

  def extract_region
    # Extract region from location header
    location = http['location']
    location.split('.').first.gsub('s3-', '') if location
  end

  def is_public?
    # Check if bucket policy allows public read
    policy = fetch_policy
    policy['Statement'].any? { |s| s['Effect'] == 'Allow' && s['Principal'] == '*' }
  end

  def fetch_policy
    uri = URI.parse(@domain)
    req = Net::HTTP::Get.new(uri.path + '?policy')
    http = Net::HTTP.new(uri.host, uri.port)
    http.request(req)
  rescue => e
    nil
  end

  def has_objects?
    !http.body.empty?
  end

  def calculate_size
    # Simple estimation based on content length
    http['content-length'].to_i
  end
end

class Scanner
  def initialize(list)
    @list = list
  end

  def scan
    @list.each do |word|
      bucket = S3.new word
      
      if bucket.exists?
        result = {
          bucket: bucket.bucket,
          status: bucket.code,
          metadata: bucket.metadata
        }
        
        puts "Found bucket: #{bucket.bucket} (#{bucket.code})".red
        puts JSON.pretty_generate(result)
      end
    end
  end
end

class Wordlist
  ENVIRONMENTS = %w(dev development stage s3 staging prod production test)
  PERMUTATIONS = %i(permutation_raw permutation_envs permutation_host)

  class << self
    def generate(common_prefix, prefix_wordlist)
      [].tap do |list|
        PERMUTATIONS.each do |permutation|
          list << send(permutation, common_prefix, prefix_wordlist)
        end
      end.flatten.uniq
    end

    def from_file(prefix, file)
      generate(prefix, IO.read(file).split("\n"))
    end

    def permutation_raw(common_prefix, _prefix_wordlist)
      common_prefix
    end

    def permutation_envs(common_prefix, prefix_wordlist)
      [].tap do |permutations|
        prefix_wordlist.each do |word|
          ENVIRONMENTS.each do |environment|
            ['%s-%s-%s', '%s-%s.%s', '%s-%s%s', '%s.%s-%s', '%s.%s.%s'].each do |bucket_format|
              permutations << format(bucket_format, common_prefix, word, environment)
            end
          end
        end
      end
    end

    def permutation_host(common_prefix, prefix_wordlist)
      [].tap do |permutations|
        prefix_wordlist.each do |word|
          ['%s.%s', '%s-%s', '%s%s'].each do |bucket_format|
            permutations << format(bucket_format, common_prefix, word)
            permutations << format(bucket_format, word, common_prefix)
          end
        end
      end
    end
  end
end

# Enhanced features:
# 1. Metadata extraction
# 2. Public bucket detection
# 3. Size estimation
# 4. Region identification
# 5. JSON output

wordlist = Wordlist.from_file(ARGV[0], 'common_bucket_prefixes.txt')
puts "Generated wordlist from file, #{wordlist.length} items..."
Scanner.new(wordlist).scan
