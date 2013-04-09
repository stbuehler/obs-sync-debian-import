
require 'uri'
require 'open4'
require 'openssl'
require 'bzip2'
#require 'xz'

def gpg_verify(file, sig, keyrings = [])
  command = ["gpgv"]
  keyrings.each { |keyring| command << "--keyring" << keyring }
  command << "--" << sig << file
  errors = nil
  status =
    Open4::popen4(*command) do |pid, stdin, stdout, stderr|
      stdin.close

      errors = stderr.readlines
    end

    if !status.success?
      STDERR.puts errors
      msg = errors.map { |line| line[6..-1].chomp }.join '; '
      return msg
    end

    return true
end

def url_to_filename(uri)
  "#{uri.hostname}#{uri.path}".gsub(/\/+/, '_')
end

class DebianVersion
  # epoch:upstream-revision
  BASIC_REGEX = /^(?:([a-zA-Z0-9.+~-]*?):)?([a-zA-Z0-9.+~:-]*)(?:-([a-zA-Z0-9.+~:]*))?$/
  EPOCH = /^[0-9]*$/
  REVISION = /^[a-zA-Z0-9+.~]*$/
  SCAN = /(?!$)([a-zA-Z.+~:-]*)([0-9]*)/
  REPLACE = { '~' => '!', '+' => '{', '-' => '|', '.' => '}', ':' => '~' }.freeze

  include Comparable
  attr_reader :version, :epoch, :upstream, :revision, :cmp

  def initialize(version)
    self.version = version
  end

  def _scan_version(v)
    v.scan(SCAN).map do |s,i|
      [s.each_char.map { |c| REPLACE[c] || c }.join('') + '#',i.to_i]
    end.flatten
  end

  def version=(version)
    raise "Invalid debian version" unless match = BASIC_REGEX.match(version)
    raise "Invalid epoch" unless EPOCH.match(match[1].to_s)
    raise "Invalid debian revision '#{match[3]}'" unless REVISION.match(match[3].to_s)
    @epoch = match[1].to_i
    @upstream = match[2].to_s
    @revision = match[3].to_s
    @version = version
    @cmp = [@epoch, _scan_version(@upstream), _scan_version(@revision)]
  end

  def <=>(other)
    @cmp <=> other.cmp
  end

  def self.compare(a, b)
    DebianVersion.new(a) <=> DebianVersion.new(b)
  end

  def internal
    "#{cmp[0]}:#{cmp[1].join ''}|#{cmp[2].join ''}"
  end

  def to_s
    @version
  end
end

class DebPackageSelection
  attr_reader :selection

  def initialize(index, arch)
    @index = index
    @index.index_provides
    @arch = arch
    @selection = {}
  end

  def select_essentials
    essentials = []
    @index.packages.each do |pname, parchs|
      parchs.each do |arch, pinfo|
        if arch == 'all' || arch == @arch
          essentials << pname if pinfo["Essential"] == "yes"
        end
      end
    end
    select(*essentials)
  end

  def select_build_essentials
    select('build-essential')
  end

  def _find(package)
    p = @index.packages[package]
    if p
      pa = p[@arch] || p['all']
      return pa if pa
    end
    p = @index.provides[package]
    if p
      (p[@arch].to_a + p['all'].to_a).each do |prov|
        pp = _find(prov)
        return pp if pp
      end
    end
  end

  def _add_dependencies(queue, depends)
    # ignore any version stuff for now
    depends.to_s.gsub(/\([^\)]*\)/, '').split(/,/).each do |dep|
      use = dep.split(/\|/).find do |alt|
        alt.strip!
        alt = _find(alt)
        queue << alt['Package'] if alt
      end
      raise "Cannot fulfill dependency #{dep.inspect}" unless use
    end
  end

  def select(*packages)
    q = packages.clone
    while (p = q.shift)
      next if @selection.has_key? p
      pinfo = _find(p)
      raise "Package #{p.inspect} not found" unless pinfo
      _add_dependencies(q, pinfo["Pre-Depends"])
      _add_dependencies(q, pinfo["Depends"])
      (@selection[p] ||= []) << [p, pinfo['Architecture']]
    end
  end

  def self.merge(*selections)
    sel = selections.inject({}) do |acc, s|
      acc.merge!(s.selection) do |key,oldval,newval|
        (oldval + newval).uniq
      end
    end
    sel.values.flatten(1)
  end
end

class DebPackagesParser
  def initialize(app, baseurl, fileinfo)
    @app = app
    @baseurl = baseurl
    @fileinfo = fileinfo
  end

  FIELDS = Hash.new(['Filename', 'Package', 'Architecture', 'Version', 'Depends', 'Pre-Depends',
    'Provides', 'Essential', 'MD5sum', 'SHA1', 'SHA256', 'Size'].map {|v| [v,true]}).freeze

  def to_enum
    Enumerator.new do |y|
      file = File.open(@fileinfo[:outputfile], "rb")
      begin
        if @fileinfo[:compression] == ".gz"
          file = Zlib::GzipReader.new file
        elsif @fileinfo[:compression] == ".bz2"
          file = Bzip2::Reader.new file
        elsif @fileinfo[:compression] == ".xz"
          file = XZ::StreamReader.new file
        elsif @fileinfo[:compression] != ""
          raise "Unknown compression #{@fileinfo[:compression]}"
        end

        #file.set_encoding(Encoding::UTF_8)
        fsize = (@fileinfo[:uncompressed_size]).to_f
        begin
          fsize = file.size.to_f
        rescue Exception => e
        end
        pos = 0

        package = {}
        key = nil
        file.each_line do |line|
          pos += line.bytesize
          if match = /^[ \t]*$/.match(line)
            unless package.empty?
              package["Url"] = URI.join(@baseurl, package["Filename"])
              y.yield(package, fsize > 0 ? pos / fsize : 0)
            end
            key = nil
            package = {}
          elsif match = /^([a-zA-Z0-9_\-]+)[ \t]*:[ \t]*(.*?)[ \t\r\n]+$/.match(line)
            key = match[1]
            package[key] = match[2] if FIELDS[key]
            #key = "LongDescription" if key == "Description"
          elsif match = /^[ \t]+(.*?)[ \t\r\n]+$/.match(line)
            if FIELDS[key]
              match = "" if match == "."
              if package[key]
                package[key] += "\n" + match[1]
              elsif !match[1].empty?
                package[key] = match[1]
              end
            end
          end
        end
        unless package.empty?
          package["Url"] = URI.join(@baseurl, package["Filename"])
          y.yield(package, fsize > 0 ? pos / fsize : 0)
        end
      ensure
        file.close
      end
    end
  end

  def url
    @fileinfo[:url]
  end
end

class DebParseRelease
  HASHKEYS = ['SHA256Sum', 'SHA1Sum', 'MD5Sum'].freeze
  HASHKEYS_SYMS = HASHKEYS.map { |h| h[0..-4].to_sym }.freeze
  COMPRESSIONS = ['.gz', '.bz2', '.xz'].freeze

  def initialize(app, baseurl, filename)
    @app = app
    @baseurl = baseurl
    @files = { }
    @info = { }
    File.open(filename, "rb") do |file|
      file.set_encoding(Encoding::UTF_8)
      key = nil
      file.each_line do |line|
        if match = /^([a-zA-Z0-9_\-]+)[ \t]*:[ \t]*(.*?)[ \t\r\n]+$/.match(line)
          key = match[1]
          _addinfo(key, match[2])
        elsif match = /^[ \t]+(.*?)[ \t\r\n]+$/.match(line)
          _addinfo(key, match[1])
        end
      end
    end
  end

  def _addinfo(key, value)
    return if value.empty?
    if HASHKEYS.include? key
      checksumtype = key[0..-4].to_sym
      if match = /^([a-fA-F0-9]+)[ \t]+([0-9]+)[ \t]+([^ \t]+)$/.match(value)
        _addfile(checksumtype, match[1], match[2].to_i, match[3])
      else
        raise "Release file: cannot parse #{key} file info line #{value.inspect}"
      end
    elsif @info.has_key? key
      @info[key] += "\n" + value
    else
      @info[key] = value
    end
  end
  protected :_addinfo

  def _addfile(checksumtype, checksum, size, filename)
    comp = COMPRESSIONS.find { |c| filename.end_with? c }.to_s
    filename = filename.slice(0, filename.length - comp.length)
    f = (@files[filename] ||= {})
    f = (f[comp] ||= {})
    raise "Release file: inconsistent file sizes for #{(filename + comp).inspect}" if !f[:size].nil? && f[:size] != size
    raise "Release file: already have #{checksumtype} for #{(filename + comp).inspect}" if !f[checksumtype].nil?
    f[:size] = size
    f[checksumtype] = checksum
  end
  protected :_addfile

  def download(filename)
    files = @files[filename]
    raise "Release didn't contain file #{filename}" unless files
    comp, file = files.min_by { |k,v| v[:size] }
    url = URI.join(@baseurl, filename + comp)
    outputfile = File.join(@app.listsdir, url_to_filename(url))

    info = {
      :compression => comp,
      :outputfile => outputfile,
      :filename => filename,
      :url => url,
      :uncompressed_size => files[''] && files[''][:size]
    }

    verifiers = []
    ctype = HASHKEYS_SYMS.find { |h| file.has_key? h }
    verifiers << DigestVerifier.new(ctype.to_s, file[ctype]) if ctype
    verifiers << SizeVerifier.new(file[:size])
    DownloadManager.start.wait(Download.new(url, outputfile, verifiers))
    info
  end
end

class DebianArchiveLoader
  def initialize(app, line)
    deb, uri, suite, *components = line.lstrip.split /\s+/
    raise "Cannot handle #{deb} lines, expected 'deb'" unless deb == "deb"

    raise "Distribution is exact path (ends in /), mustn't list components" if suite[-1] == '/' && !components.empty?

    raise "No components and suite is not an exact path (doesn't end in /)" if suite[-1] != '/' && components.empty?

    uri += '/' unless uri[1] == '/'
    uri = URI(uri)

    @app = app
    @all_archs = (@app.architectures.clone << 'all').uniq

    @uri = uri
    @suite = suite
    @components = components
  end

  def signed_download(url, urlgpg)
    file = File.join(@app.listsdir, url_to_filename(url))
    filegpg = File.join(@app.listsdir, url_to_filename(urlgpg))
    c = Collector.new
    DownloadManager.start.wait(Download.new(url, file, []), Download.new(urlgpg, filegpg, []))
    msg = gpg_verify(file, filegpg, @app.keyrings)
    raise msg unless msg == true
    return file
  end

  # "Automatic" repositories (standard repos)
  def _load_automatic(&block)
    dir = URI.join(@uri, "dists/#{@suite}/")

    file = signed_download(URI.join(dir, 'Release'), URI.join(dir, 'Release.gpg'))

    release = DebParseRelease.new(@app, dir, file)
    c = Collector.new
    c.run_each(@all_archs.product(@components)) do |ac|
      pinfo = release.download("#{ac[1]}/binary-#{ac[0]}/Packages")

      parser = DebPackagesParser.new(@app, @uri, pinfo)
      block.call(parser)
    end
    c.wait_throw
  end

  # "Trivial" repositories (openbuildservice, other custom stuff)
  def _load_trivial(&block)
    dirs = @all_archs.map { |arch| URI.join(@uri, @suite.gsub(/\$\(ARCH\)/, arch)) }.uniq
    c = Collector.new
    c.run_each(dirs) do |dir|
      file = signed_download(URI.join(dir, 'Release'), URI.join(dir, 'Release.gpg'))

      release = DebParseRelease.new(@app, dir, file)

      pinfo = release.download('Packages')

      parser = DebPackagesParser.new(@app, dir, pinfo)
      block.call(parser)
    end
    c.wait_throw
  end

  def load(&block)
    if @components.empty?
      _load_trivial(&block)
    else
      _load_automatic(&block)
    end
  end
end

class DebianIndex
  attr_reader :packages

  def initialize(app)
    @app = app
    @packages = {}
    @have_provides = false
    @mutex = Mutex.new
  end

  def provides
    index_provides unless @have_provides
    @provides
  end

  def index_provides
    @mutex.synchronize do
      return if @have_provides
      progress = ProgressDisplay.start.new("Indexing provides")
      total = @packages.size.to_f
      pos = 0
      @provides = {}
      @packages.each_value do |parchs|
        progress.update(pos / total)
        pos += 1
        parchs.each_value do |info|
          info["Provides"].to_s.gsub(/\([^\)]*\)/, '').split(/,/).each do |dep|
            dep.strip!
            p = (@provides[dep] ||= {})
            pa = (p[info["Architecture"]] ||= [])
            pa << info["Package"]
          end
        end
      end
      @have_provides = true
      progress.finish
    end
  end

  def _add_packages(parser)
    @mutex.synchronize do
      raise "Index already frozen" if @have_provides
      progress = ProgressDisplay.start.new("Indexing #{parser.url.to_s}")
      parser.to_enum.each do |info, pos|
        progress.update(pos)
        p = (@packages[info["Package"]] ||= {})
        old = p[info["Architecture"]]
        if old
          if DebianVersion.compare(old["Version"], info["Version"]) < 0
            p[info["Architecture"]] = info
          end
        else
          p[info["Architecture"]] = info
        end
      end
      progress.finish
    end
  end

  def load(line)
    l = DebianArchiveLoader.new(@app, line)
    l.load { |parser| _add_packages(parser) }
  end

  def _download(pinfo)
    filename = pinfo["Package"] + "_" + pinfo["Version"] + "_" + pinfo["Architecture"] + ".deb"
    ctype = ['SHA256', 'SHA1', 'MD5Sum'].find { |t| pinfo[t] }
    verifiers = []
    verifiers << DigestVerifier.new(ctype.sub(/Sum$/, ''), pinfo[ctype], true) if ctype
    verifiers << SizeVerifier.new(pinfo["Size"].to_i)
    DownloadManager.start.add(Download.new(pinfo["Url"], File.join(@app.pkgdir, filename), verifiers, true, false))
    filename
  end

  def _find_all(package, arch)
    p = @packages[package]
    return [] unless p
    return [p[arch] || p['all']] if arch
    return p.values_at(*@app.all_architectures).compact
  end

  def download(packages)
    files = []
    packages.each do |package, arch|
      _find_all(package, arch).each { |pinfo| files << _download(pinfo) }
    end
    files.sort!
  end

  def download_all
    files = []
    @packages.each_value do |parchs|
      parchs.values_at(*@app.all_architectures).compact.each { |pinfo| files << _download(pinfo) }
    end
    files.sort!
  end

  def files(packages)
    files = []
    packages.each do |package, arch|
      _find_all(package, arch).each { |pinfo| files << pinfo["Package"] + "_" + pinfo["Version"] + "_" + pinfo["Architecture"] + ".deb" }
    end
    files.sort!
  end

  def files_all
    files = []
    @packages.each_value do |parchs|
      parchs.values_at(*@app.all_architectures).compact.each { |pinfo| files << pinfo["Package"] + "_" + pinfo["Version"] + "_" + pinfo["Architecture"] + ".deb" }
    end
    files.sort!
  end

  def size(packages)
    sum = 0
    packages.each do |package, arch|
      _find_all(package, arch).each { |pinfo| sum += pinfo['Size'].to_i }
    end
    sum
  end

  def size_all
    sum = 0
    @packages.each_value do |parchs|
      parchs.values_at(*@app.all_architectures).compact.each { |pinfo| sum += pinfo['Size'].to_i }
    end
    sum
  end
end
