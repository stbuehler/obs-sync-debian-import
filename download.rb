require 'uri'
require 'net/http'
require 'tempfile'
require 'openssl'

def as_size(s)
  # http://codereview.stackexchange.com/questions/9107/printing-human-readable-number-of-bytes
  units = %W(B KiB MiB GiB TiB)

  size, unit = units.reduce(s.to_f) do |(fsize, _), utype|
    fsize > 512 ? [fsize / 1024, utype] : (break [fsize, utype])
  end

  "#{size > 9 || size.modulo(1) < 0.1 ? '%d' : '%.1f'} %s" % [size, unit]
end

class DownloadVerifier
  def update(chunk)
    return true
  end

  def finish
    return true
  end

  def reset
    nil
  end

  def fast_verify_file(file)
    return nil
  end
end

class DigestVerifier < DownloadVerifier
  def initialize(method, hexchecksum, trustlocal = false)
    @method = method
    @hexchecksum = hexchecksum
    @trustlocal = trustlocal
  end

  def update(chunk)
    @digest.update(chunk)
    return true
  end

  def finish
    return true if @digest.hexdigest == @hexchecksum
    return "checksum mismatch"
  end

  def reset
    @digest = OpenSSL::Digest.new(@method)
  end

  def fast_verify_file(file)
    return true if @trustlocal
    return nil
  end
end

class SizeVerifier < DownloadVerifier
  def initialize(size)
    @size = size.to_i
  end

  def update(chunk)
    @have += chunk.bytesize
    return true
  end

  def finish
    return true if @have = @size
    return "size mismatch"
  end

  def reset
    @have = 0
  end

  def fast_verify_file(file)
    return file.stat.size == @size ? true : "size mismatch: #{file.stat.size} != #{@size}"
  end
end

class DownloadMethod
  @@schemes = {}
  def self.register(scheme, klass)
    @@schemes[scheme] = klass
  end

  def self.get(uri, lastmtime = nil, max_redirects = 10, &block)
    uri = URI(uri)
    klass = @@schemes[uri.scheme]
    raise "#{uri.scheme} downloads not supported" unless klass
    raise "Redirect limit exceeded" unless max_redirects > 0
    o = klass.new(uri, lastmtime, max_redirects)
    o.get(&block)
    o
  end

  def initialize(uri, lastmtime, max_redirects)
    @uri = uri
    @lastmtime = lastmtime
    @max_redirects = max_redirects
  end

  def get(&block)
    # block.call(nil) if cache has the right file
    # block.call(<Enumerator>) to deliver content
    raise "abstract method not implemented"
  end
end

class DownloadMethodHTTP < DownloadMethod
  self.register('http', self)
  #self.register('https', self)

  def get(&block)
    Net::HTTP.start(@uri.host, @uri.port) do |http|
      request = Net::HTTP::Get.new @uri.request_uri
      request["If-Modified-Since"] = @lastmtime.getutc.strftime('%a, %d %b %Y %H:%M:%S GMT') if @lastmtime
      http.request request do |response|
        return DownloadMethod.get(response["Location"], @lastmtime, @max_redirects - 1, &block) if 302 == response.code.to_i
        return block.call(nil) if 304 == response.code.to_i && @lastmtime

        raise "Unexpected response code #{response.code}" if 200 != response.code.to_i
        content_length = response['Content-Length']
        content_length = content_length.to_i unless content_length.nil?

        data_enumerator = Enumerator.new { |y|
          have = 0
          response.read_body do |chunk|
            have += chunk.bytesize
            progress = content_length.to_i > 0 ? have.to_f / content_length : 0
            y << [chunk, progress]
          end
          raise "Unexpected response body size: #{have} != #{content_length}" if !content_length.nil? && have != content_length
        }
        block.call(data_enumerator)
      end
    end
  end
end

class Download
  attr_reader :url, :uri, :outputfile, :verifiers, :lastmtime, :checkmtime
  attr_accessor :extra_callback

  def initialize(url, outputfile = nil, verifiers = [], allowcache = true, checkmtime = true, &callback)
    @url = url
    @uri = URI(url)
    @outputfile = outputfile
    @verifiers = (verifiers || [])
    @callback = callback
    @extra_callback = nil
    @lastmtime = nil
    @checkmtime = checkmtime
    @allowcache = allowcache
  end

  def checkcache
    if @allowcache && !@outputfile.nil?
      begin
        f = File.open(@outputfile, "rb")
        verifiers = @verifiers.clone
        verifiers.delete_if do |v|
          res = v.fast_verify_file(f)
          if !res.nil?
            if true == res
              true
            else
              raise "verify failed: #{res}"
            end
          end
        end
        if !verifiers.empty?
          verifiers.each { |v| v.reset }
          while !f.eof?
            chunk = f.readpartial(16384)
            verifiers.each do |v|
              res = v.update(chunk)
              raise "verify failed: #{res}" if true != res
            end
          end
          verifiers.each do |v|
            res = v.finish
            raise "verify failed: #{res}" if true != res
          end
        end
        @lastmtime = f.stat.mtime
      rescue Exception => e
        #$stderr.puts "cache entry not valid: #{e}"
      end
    end
  end

  def success(file)
    begin
      @callback.call(file, nil) if !@callback.nil?
    ensure
      @extra_callback.call(file, nil) if !@extra_callback.nil?
    end
  end

  def failed(msg)
    begin
      @callback.call(nil, msg) if !@callback.nil?
    ensure
      @extra_callback.call(nil, msg) if !@extra_callback.nil?
    end
  end

  def to_s
    @uri.to_s + (!@outputfile.nil? ? " => " + File.basename(@outputfile) : "")
  end
end

class DownloadManager < JobQueue
  @@downloadmanager = nil
  def self.start(worker_count = 10)
    @@downloadmanager = DownloadManager.new(worker_count) unless @@downloadmanager
    @@downloadmanager
  end

  def initialize(worker_count)
    super(worker_count)
  end

  def self.atomic_write(file_name, temp_dir = Dir.tmpdir, tmp_name = nil)
    # http://apidock.com/rails/File/atomic_write/class
    require 'tempfile' unless defined?(Tempfile)
    require 'fileutils' unless defined?(FileUtils)

    tmp_name = file_name if tmp_name.nil?
    temp_file = Tempfile.new(File.basename(tmp_name), temp_dir)
    temp_file.binmode
    begin
      yield temp_file
    ensure
      temp_file.close
    end
    # BUG!!! temp_file will try to delete the moved file later

    begin
      # Get original file permissions
      old_stat = File.stat(file_name)
    rescue Errno::ENOENT
      # No old permissions, write a temp file to determine the defaults
      check_name = File.join(File.dirname(file_name), ".permissions_check.#{Thread.current.object_id}.#{Process.pid}.#{rand(1000000)}")
      File.open(check_name, "w") { }
      old_stat = File.stat(check_name)
      File.unlink(check_name)
    end

    # Overwrite original file with temp file
    FileUtils.mv(temp_file.path, file_name)

    # Set correct permissions on new file
    begin
      File.chown(old_stat.uid, old_stat.gid, file_name)
      # This operation will affect filesystem ACL's
      File.chmod(old_stat.mode, file_name)
    rescue Errno::EPERM
      # Changing file ownership failed, moving on.
    end
  end

  def self.download_file(uri, outputfile, &block)
    template = uri.to_s.gsub(/[^a-zA-Z0-9-]+/, '_')
    if outputfile.nil?
      tmpfile = Tempfile.new(template)
      block.call(tmpfile)
      return tmpfile
    else
      atomic_write(outputfile, Dir.tmpdir, template, &block)
      return File.open(outputfile, "r")
    end
  end

  def doRun(download)
    progress = ProgressDisplay.start.new("GET #{download.uri.to_s}")
    download.checkcache
    if download.lastmtime && !download.checkmtime
      download.success(download.outputfile)
      progress.finish("cache")
      return
    end
    success = false
    msg = nil
    content_length = nil
    outfile = nil
    begin
      DownloadMethod.get(download.uri, download.lastmtime) do |response|
        if response.nil?
          success = "Not modified"
          next
        end

        outfile = self.class.download_file(download.uri, download.outputfile) do |tmpfile|
          verifiers = download.verifiers
          verifiers.each { |v| v.reset }

          response.each do |chunk, p|
            verifiers.each do |v|
              raise msg if true != (msg = v.update(chunk))
            end
            tmpfile.write chunk
            progress.update(p, false)
          end
          verifiers.each do |v|
            raise msg if true != (msg = v.finish)
          end
          success = as_size(tmpfile.length)
        end
      end
    rescue Exception => e
      success = false
      msg = e.to_s
      $stderr.puts "#{e}\n#{e.backtrace.join "\n"}"
    end
    if success
      download.success(outfile)
      progress.finish(success)
    else
      download.failed(msg)
      progress.failed(msg.inspect)
    end
  end

  def wait(*downloads)
    return [] if downloads.empty?
    c = Collector.new
    downloads.each do |download|
      download.extra_callback = c.collect
      add(download)
    end
    results, error = c.get
    raise error unless error.nil?
    downloads.size == 1 ? results[0] : results
  end
end
