unless ENV['RAILS_ENV'] == 'test'
  begin
    require 'daemons'
  rescue LoadError
    raise "You need to add gem 'daemons' to your Gemfile if you wish to use it."
  end
end
require 'fileutils'
require 'optparse'
require 'pathname'

module Delayed
  class Command # rubocop:disable ClassLength
    attr_accessor :worker_count, :worker_pools

    DIR_PWD = Pathname.new Dir.pwd

    def initialize(args, **options) # rubocop:disable MethodLength
      @options = {
        :quiet => true,
        :pid_dir => "#{root}/tmp/pids",
        :log_dir => "#{root}/log"
      }.merge!(options)

      @monitor = false

      opts = OptionParser.new do |opt|
        opt.banner = "Usage: #{File.basename($PROGRAM_NAME)} [options] start|stop|restart|run"

        opt.on('-h', '--help', 'Show this message') do
          puts opt
          exit 1
        end
        opt.on('-e', '--environment=NAME', 'Specifies the environment to run this delayed jobs under (test/development/production).') do |_e|
          STDERR.puts 'The -e/--environment option has been deprecated and has no effect. Use RAILS_ENV and see http://github.com/collectiveidea/delayed_job/issues/7'
        end
        opt.on('--min-priority N', 'Minimum priority of jobs to run.') do |n|
          @options[:min_priority] = n
        end
        opt.on('--max-priority N', 'Maximum priority of jobs to run.') do |n|
          @options[:max_priority] = n
        end
        opt.on('-n', '--number_of_workers=workers', 'Number of unique workers to spawn') do |worker_count|
          @worker_count = worker_count.to_i rescue nil
        end
        opt.on('--pid-dir=DIR', 'Specifies an alternate directory in which to store the process ids.') do |dir|
          @options[:pid_dir] = dir
        end
        opt.on('--log-dir=DIR', 'Specifies an alternate directory in which to store the delayed_job log.') do |dir|
          @options[:log_dir] = dir
        end
        opt.on('-i', '--identifier=n', 'A numeric identifier for the worker.') do |n|
          @options[:identifier] = n
        end
        opt.on('-m', '--monitor', 'Start monitor process.') do
          @monitor = true
        end
        opt.on('--sleep-delay N', 'Amount of time to sleep when no jobs are found') do |n|
          @options[:sleep_delay] = n.to_i
        end
        opt.on('--read-ahead N', 'Number of jobs from the queue to consider') do |n|
          @options[:read_ahead] = n
        end
        opt.on('-p', '--prefix NAME', 'String to be prefixed to worker process names') do |prefix|
          @options[:prefix] = prefix
        end
        opt.on('--queues=queues', 'Specify which queue DJ must look up for jobs') do |queues|
          @options[:queues] = queues.split(',')
        end
        opt.on('--queue=queue', 'Specify which queue DJ must look up for jobs') do |queue|
          @options[:queues] = queue.split(',')
        end
        opt.on('--pool=queue1[,queue2][:worker_count]', 'Specify queues and number of workers for a worker pool') do |pool|
          parse_worker_pool(pool)
        end
        opt.on('--exit-on-complete', 'Exit when no more jobs are available to run. This will exit if all jobs are scheduled to run in the future.') do
          @options[:exit_on_complete] = true
        end
        opt.on('--daemon-options a, b, c', Array, 'options to be passed through to daemons gem') do |daemon_options|
          @daemon_options = daemon_options
        end
      end

      @args = opts.parse!(args) + (@daemon_options || [])
      @worker_count ||= default_workers

      @args
    end

    def process_name(index)
      if @options[:identifier]
        "delayed_job.#{@options[:identifier]}.#{index}"
      else
        "delayed_job.#{index}"
      end
    end

    def default_workers
      # this is an attempt to auto-detect the number of workers when .pid files are present
      dir = @options[:pid_dir]
      entries = Dir["#{dir}/delayed_job.*"]

      filenames = entries.map { |file|
        file.split('/').last
      }.select { |file|
        file.end_with? '.pid'
      }

      largest_index = filenames.reduce(0) do |memo, file|
        index = file.split('.')[-2].to_i rescue 0
        index > memo ? index : memo
      end

      [largest_index + 1, filenames.length].max
    end

    def daemonize # rubocop:disable PerceivedComplexity
      dir = @options[:pid_dir]
      FileUtils.mkdir_p(dir) unless File.exist?(dir)

      if worker_pools
        setup_pools
      else
        worker_count.times do |worker_index|
          run_process(process_name(worker_index), @options)
        end
      end
    end

    def setup_pools
      worker_index = 0
      @worker_pools.each do |queues, worker_count|
        options = @options.merge(:queues => queues)
        worker_count.times do
          run_process(process_name(worker_index), options)
          worker_index += 1
        end
      end
    end

    def run_process(process_name, options = {})
      Delayed::Worker.before_fork
      Daemons.run_proc(process_name, :dir => options[:pid_dir], :dir_mode => :normal, :monitor => @monitor, :force_kill_waittime => options[:force_kill_waittime], :ARGV => @args) do |*_args|
        $0 = File.join(options[:prefix], process_name) if @options[:prefix]
        run process_name, options
      end
    end

    def run(worker_name = nil, options = {})
      Dir.chdir(root)

      Delayed::Worker.after_fork
      Delayed::Worker.logger ||= Logger.new(File.join(@options[:log_dir], 'delayed_job.log'))

      worker = Delayed::Worker.new(options)
      worker.name_prefix = "#{worker_name} "
      worker.start
    rescue => e
      STDERR.puts e.message
      STDERR.puts e.backtrace
      ::Rails.logger.fatal(e) if rails_logger_defined?
      exit_with_error_status
    end

  private

    def parse_worker_pool(pool)
      @worker_pools ||= []

      queues, worker_count = pool.split(':')
      queues = ['*', '', nil].include?(queues) ? [] : queues.split(',')
      worker_count = (worker_count || 1).to_i rescue 1
      @worker_pools << [queues, worker_count]
    end

    def root
      @root ||= rails_root_defined? ? ::Rails.root : DIR_PWD
    end

    def rails_root_defined?
      defined?(::Rails.root)
    end

    def rails_logger_defined?
      defined?(::Rails.logger)
    end

    def exit_with_error_status
      exit 1
    end
  end
end
