#!/usr/bin/env ruby
require './boot'

class Deadlock < RuntimeError; end

def clean_rabbitmq
  run <<-SCRIPT, "Purging RabbitMQ", :tag => :pub
    sudo rabbitmqctl stop_app   &&
    sudo rabbitmqctl reset      &&
    sudo rabbitmqctl start_app  &&
    sleep 1
  SCRIPT
end

def update_hosts
  run <<-SCRIPT, "Updating /etc/hosts"
    HOST=`/root/get_abricot_redis`
    sed -i "s/^.* master$/$HOST master/" /etc/hosts
  SCRIPT
end

def update_app
  run <<-SCRIPT, "app git pull"
    cd /srv/promiscuous-benchmark/playback_pub
    git pull
    # git reset --hard origin/master
    # unset BUNDLE_GEMFILE
    # unset RVM_ENV
    # unset BUNDLE_BIN_PATH
    # unset RUBYOPT
    # rvm ruby-2.0@promiscuous-benchmark do bundle install
    # cd /srv/promiscuous-benchmark/playback_sub
    # rvm ruby-2.0@promiscuous-benchmark do bundle install
  SCRIPT
end

def run_publisher(options={})
  run <<-SCRIPT, "Running publishers", options.merge(:tag => :pub)
    cd /srv/promiscuous-benchmark/playback_pub

    export MAX_NUM_FRIENDS=#{options[:max_num_friends]}
    export COEFF_NUM_FRIENDS=#{options[:coeff_num_friends]}
    export NUM_USERS=#{options[:num_users]}
    export COEFF_FRIEND_ACTIVITY=#{options[:coeff_friend_activity]}

    #{"export NUM_REDIS=#{options[:num_pub_redis]}" if options[:num_pub_redis]}
    #{"export PUB_LATENCY=#{options[:pub_latency]}" if options[:pub_latency]}
    #{ruby_exec "./pub.rb"}
  SCRIPT
end

def run_subscriber(options={})
  run <<-SCRIPT, "Running subscribers", options.merge(:tag => :sub)
    cd /srv/promiscuous-benchmark/playback_sub

    export CLEANUP_INTERVAL=#{options[:cleanup_interval]}
    export QUEUE_MAX_AGE=#{options[:queue_max_age]}

    #{"export NUM_REDIS=#{options[:num_sub_redis]}" if options[:num_sub_redis]}
    #{"export SUB_LATENCY=#{options[:sub_latency]}" if options[:sub_latency]}
    #{ruby_exec "./sub.rb"}
  SCRIPT
end

def register_redis_ips
  run <<-SCRIPT, "Prepping redis (sub)", :tag => :sub_redis
    redis-cli -h localhost flushdb
    redis-cli -h master rpush ip:sub_redis `hostname -i`
  SCRIPT

  run <<-SCRIPT, "Prepping redis (pub)", :tag => :pub_redis
    redis-cli -h localhost flushdb
    redis-cli -h master rpush ip:pub_redis `hostname -i`
  SCRIPT
end

def run_benchmark(options={})
  kill_all
  @master.flushdb

  options[:max_num_friends] = 500
  options[:coeff_num_friends] = 0.8
  options[:coeff_friend_activity] = 1

  options[:num_pub_redis] = 3
  options[:num_sub_redis] = 3

  options[:cleanup_interval] = 10
  options[:queue_max_age] = 50

  @abricot.multi do
    clean_rabbitmq
    register_redis_ips
  end

  jobs = @abricot.multi :async => true do
    run_publisher(options)
    run_subscriber(options)
  end

  start = Time.now
  loop do
    sleep 0.1
    jobs.check_for_failures
    break if @master.llen("ip:sub") == options[:num_workers]
    if Time.now - start > 30
      jobs.kill
      raise Deadlock
    end
  end

  STDERR.puts 'Starting...'
  @master.set("start_pub", "1")
  jobs
end


def _rate_sample
  num_samples = 120 # must be divisible by 4
  num_dropped = num_samples / 4

  num_msg_since_last = @master.getset('sub_msg', 0).to_i
  new_time, @last_time_read = @last_time_read, Time.now
  return unless new_time

  delta = @last_time_read - new_time
  rate = num_msg_since_last / delta


  if @rates.size >= 5 && @rates[-5..-1].all? { |r| r.zero? }
    raise Deadlock
  end

  @rates << rate
  STDERR.puts "Sampling: #{rate.round(1)}q/s #{@rates.size}/#{num_samples}"
  return unless @rates.size == num_samples

  sampled_rates = @rates.sort_by { |x| -x }.to_a[num_dropped/2 ... -num_dropped/2]
  avg_rate = sampled_rates.reduce(:+) / sampled_rates.size.to_f

  STDERR.puts "Sampling avg rate: #{avg_rate}"
  return avg_rate
end

def rate_sample_workers(options={})
  unless @worker_rates
    @worker_rates = {}
    options[:num_workers].times.each { |i| @worker_rates[i] = [] }
  end

  rates = @master.mget(options[:num_workers].times.map { |i| "pub_msg:#{i}" })
  rates.each_with_index { |r, i| @worker_rates[i] << r.to_i }

  @worker_rates.each do |i, worker_rate|
    normalized_rates = []
    last_rate = 0
    worker_rate.each { |r| normalized_rates << r - last_rate; last_rate = r }
    puts "worker #{i}: #{normalized_rates}"
  end
end

def rate_sample(jobs, options={})
  @last_time_read = nil
  @rates = []
  loop do
    sleep 1
    rate_sample_workers(options)
    jobs.check_for_failures
    rate = _rate_sample
    return rate if rate
  end
end

def benchmark_once(num_users, num_workers)
  tries = 3

  begin
    tries -= 1
    options = {:num_users => num_users, :num_workers => num_workers}
    jobs = run_benchmark(options)
    rate = rate_sample(jobs, options).round(1)
    jobs.kill

    result = "#{num_users} #{num_workers} #{rate}"

    STDERR.puts ">>>>>> \e[1;36m #{result}\e[0m"
    File.open("results", "a") do |f|
      f.puts result
    end
  rescue Deadlock
    jobs.kill if jobs
    STDERR.puts ">>>>>> \e[1;31m Deadlocked :(\e[0m"
    if tries > 0
      STDERR.puts ">>>>>> \e[1;31m Retrying...\e[0m"
      retry
    end
  end
end

def benchmark_all
  num_workers = [1,3,5,10,30,50]
  num_users = [3, 30]
  # num_users = [1, 10, 100, 1000]

  num_users.each do |nu|
    num_workers.each do |nw|
      benchmark_once(nu, nw)
    end
  end
end

begin
  kill_all
  @master = Redis.new(:url => 'redis://master/')
  # update_hosts
  # update_app
  # benchmark_all
  benchmark_once(30000, 50)

  # ENV['MAX_NUM_FRIENDS'] = 100.to_s
  # ENV['COEFF_NUM_FRIENDS'] = 0.8.to_s
  # ENV['WORKER_INDEX'] = 0.to_s
  # ENV['NUM_WORKERS'] = 7.to_s
  # ENV['NUM_USERS'] = 30.to_s
  # ENV['COEFF_FRIEND_ACTIVITY'].to_f
rescue Exception => e
  STDERR.puts
  STDERR.puts
  STDERR.puts
  STDERR.puts e.message
  STDERR.puts
  STDERR.puts
  STDERR.puts
end
