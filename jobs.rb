require 'thread'

class JobQueue
  @@waiting = 0
  @@mutex = Mutex.new
  @@finished = ConditionVariable.new
  @@queues = []
  @@blocking_threads = []
  @@finished_threads = []

  class << self
    def _finishedJob(queue)
      @@mutex.synchronize do
        queue[:finished].broadcast if !queue.nil? && 0 == (queue[:waiting] -= 1)
        @@finished.broadcast if 0 == (@@waiting -= 1)
      end
    end

    def _startQueue(jobqueue, worker_count)
      qqueue = Queue.new
      finished = ConditionVariable.new
      threads = []
      queue = {
        :queue => qqueue,
        :threads => threads,
        :stopped => false,
        :finished => finished,
        :waiting => 0
      }
      @@mutex.synchronize do
        worker_count.times do
          threads << Thread.new do
            while !(job = qqueue.pop).nil?
              begin
                jobqueue.doRun(job)
              rescue Exception => e
                $stderr.puts "Job failed (ignoring): #{e}\n#{e.backtrace.join "\n"}"
              ensure
                _finishedJob(queue)
              end
            end
          end
        end
        @@queues << queue
      end
      return queue
    end

    def _addJob(queue, job)
      return if job.nil?
      @@mutex.synchronize do
        raise "Queue is closed" if queue[:stopped]
        queue[:waiting] += 1
        @@waiting += 1
        queue[:queue] << job
      end
    end

    def _waitQueue(queue)
      @@mutex.synchronize do
        while 0 < queue[:waiting]
          queue[:finished].wait(@@mutex)
        end
      end
    end

    def _joinQueue(queue)
      _waitQueue(queue)
      @@mutex.synchronize do
        return if queue[:stopped]
        queue[:stopped] = true
        @@queues.delete(queue)
      end
      queue[:threads].each { |t| queue[:queue] << nil }
      queue[:threads].each { |t| t.join }
      queue[:threads] = []
    end

    def _joinFinishedThreads
      finished_threads = nil
      @@mutex.synchronize do
        finished_threads = @@finished_threads
        @@finished_threads = []
      end
      finished_threads.each { |t| t.join }
    end

    def wait
      @@mutex.synchronize do
        while 0 < @@waiting
          @@finished.wait(@@mutex)
        end
      end
    end

    def join
      wait
      blocking_threads = queues = nil
      @@mutex.synchronize do
        @@queues.each { |queue| queue[:stopped] = true }

        queues = @@queues
        @@queues = []
        blocking_threads = @@blocking_threads
        @@blocking_threads = []
      end
      queues.each do |queue|
        queue[:threads].each { |t| queue[:queue] << nil }
        queue[:threads].each { |t| t.join }
        queue[:threads] = []
      end
      blocking_threads.each { |t| t.join }
      _joinFinishedThreads
    end

    # run blocking job without queue
    def run(*args, &job)
      _joinFinishedThreads
      @@mutex.synchronize do
        @@waiting += 1
        @@blocking_threads << Thread.new do
          begin
            job.call(*args)
          rescue Exception => e
            $stderr.puts "Blocking Job failed (ignoring): #{e}\n#{e.backtrace.join "\n"}"
          ensure
            _finishedJob(nil)
            @@mutex.synchronize do
              @@finished_threads << Thread.current if @@blocking_threads.delete(Thread.current)
            end
          end
        end
      end
    end
  end

  def initialize(worker_count, &runner)
    @runner = runner
    @queue = JobQueue._startQueue(self, worker_count)
  end

  def doRun(job)
    @runner.call(job)
  end

  def add(job)
    JobQueue._addJob(@queue, job)
  end

  def wait
    JobQueue._waitQueue(@queue)
  end

  def join
    JobQueue._joinQueue(@queue)
  end
end

class Collector
  attr_reader :error

  def initialize
    @results = []
    @mutex = Mutex.new
    @finished = ConditionVariable.new
    @waiting = 0
    @error = nil
    @closed = false
  end

  def collect_each(list, method = nil, &block)
    block ||= lambda { |value| value.send(method) }
    list.each do |value|
      cb = collect
      JobQueue.run { block.call(value, &cb) }
    end
  end

  def run_each(list, method = nil, &block)
    block ||= lambda { |value| value.send(method) }
    list.each do |value|
      cb = collect
      JobQueue.run do
        begin
          cb.call(block.call(value), nil)
        rescue Exception => e
          cb.call(nil, e)
        end
      end
    end
  end

  def collect(&block)
    unless block.nil?
      cb = collect
      JobQueue.run do
        block.call(&cb)
      end
      return
    end
    index = -1
    finished = false
    @mutex.synchronize do
      raise "Collector already running" if @closed
      @waiting += 1
      index = @results.length
      @results << []
    end
    return Proc.new do |result, error|
      have_all = false
      @mutex.synchronize do
        raise "Collector already finished" if finished
        finished = true
        @error = error if @error.nil? && !error.nil?
        @results[index] = result
        @finished.broadcast if 0 == (@waiting -= 1)
      end
    end
  end

#  @@X = Mutex.new
#  def self.backtrace_for_all_threads
#    @@X.synchronize do
#      require 'pp'
#      f = $stderr
#      if Thread.current.respond_to?(:backtrace)
#        Thread.list.each do |t|
#          f.puts t.inspect
#          PP.pp(t.backtrace, f) # remove frames resulting from calling this method
#        end
#      else
#        PP.pp(caller, f) # remove frames resulting from calling this method
#      end
#      exit
#    end
#  end

  def wait
    @mutex.synchronize do
      @closed = true
      while 0 < @waiting
        @finished.wait(@mutex)
        #Collector.backtrace_for_all_threads if 0 < @waiting
      end
    end
  end

  def wait_throw
    @mutex.synchronize do
      @closed = true
      while 0 < @waiting
        @finished.wait(@mutex)
      end
      raise @error unless @error.nil?
    end
  end

  def get
    wait
    [@results,@error]
  end

  def results
    wait
    @results
  end

  def results_throw
    wait_throw
    @results
  end

  def error
    wait
    @error
  end

  def run(&callback)
    JobQueue.run do
      wait
      Thread.pass
      callback.call(@error.nil? ? @results : nil, @error)
    end
  end
end
