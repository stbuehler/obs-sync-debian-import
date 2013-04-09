#!/usr/bin/env ruby

require 'yaml'

MODULE_PATH = File.dirname(File.realpath(__FILE__))

require "#{MODULE_PATH}/jobs.rb"
require "#{MODULE_PATH}/progress-display.rb"
require "#{MODULE_PATH}/download.rb"
require "#{MODULE_PATH}/debian-archive.rb"

Thread.abort_on_exception = true

class MyConfig
  attr_reader :filename, :basedir, :yaml

  def initialize(filename)
    @filename = File.realpath(filename)
    @basedir = File.dirname(@filename)
    @yaml = YAML.load_file(@filename)
  end

  def get_path(path, default = nil)
    value = get(path, default)
    return nil if value.nil?
    return File.absolute_path(value, @basedir)
  end

  def get_paths(path, default = [])
    values = get(path)
    return default if values.nil?
    return values.map { |value| File.absolute_path(value, @basedir) }
  end

  def get(path, default = nil)
    MyConfig.get(@yaml, path, default)
  end

  def self.get(node, path, default = nil)
    path.split('.').each do |key|
      return default unless node.is_a? Hash
      return default unless node.has_key? key
      node = node[key]
    end
    return node
  end
end

if 1 != ARGV.length then
  STDERR.puts "Usage: #{$PROGRAM_NAME} config.yaml"
  exit 1
end

class Application
  attr_reader :architectures, :all_architectures, :listsdir, :pkgdir, :keyrings

  def initialize
    @config = MyConfig.new(ARGV[0])

    @architectures = @config.get('architectures', ['amd64', 'i386']).uniq
    @all_architectures = (@architectures + ['all']).uniq
    @listsdir = @config.get_path('lists-directory', 'lists')
    @pkgdir = @config.get_path('package-directory', 'packages')
    @oldpkgdir = @config.get_path('package-directory', 'old-packages')

    FileUtils.mkdir_p @listsdir
    FileUtils.mkdir_p @pkgdir
    FileUtils.mkdir_p @oldpkgdir

    @keyrings = @config.get_paths('keyrings')
    @keyrings += ((["/etc/apt/trusted.gpg"] + Dir["/etc/apt/trusted.gpg.d/*.gpg"]).select { |f| File.readable?(f) })

    @index = DebianIndex.new(self)

    ProgressDisplay.start
    DownloadManager.start(@config.get('download.parallel', 10))
  end

  def load_sources
    c = Collector.new
    c.run_each(@config.get('sources', [])) do |line|
      @index.load(line)
    end

    results, error = c.get
    if error
      raise "Couldn't load packages lists: #{error}"
    end

    self
  end

  def download_all
    #@index.download_all(@architectures)
  end

  def create_essential_set
    sel = {}
    @architectures.each do |arch|
      selection = DebPackageSelection.new(@index, arch)
      selection.select_essentials
      selection.selection.each_value do |value|
        name, arch = value[0]
        ((sel[name] ||= []) << arch).uniq!
      end
    end

    set = []
    sel.each do |name, archs|
      if archs.include?('all') || archs == @architectures
        set << name
      else
        archs.each { |arch| set << "#{name}:#{arch}" }
      end
    end

    File.open(File.join(@listsdir, 'essential_set'), "w") do |f|
      f.puts set
    end
  end

  def download(selection = nil)
    if selection
      allfiles = @index.download(selection)
    else
      allfiles = @index.download_all
    end
    allfiles.sort!
    File.open(File.join(@listsdir, 'files'), "w") do |f|
      f.puts allfiles
    end
    old = Dir.new(@pkgdir).grep /\.deb$/
    (old - allfiles).each do |filename|
      $stderr.puts "Move away #{filename}"
      #FileUtils.mv(filename, File.join(@oldpkgdir, File.basename(filename)))
    end
  end

  CHROOT_TOOLS = ['less', 'kmod', 'libdevmapper1.02.1', 'net-tools', 'procps', 'psmisc', 'strace', 'user-setup', 'vim']
  BUILD_TOOLS = ['fakeroot', 'debhelper', 'lintian']

  def download_minimal_set
    selections = @architectures.map do |arch|
      selection = DebPackageSelection.new(@index, arch)
      selection.select_essentials
      selection.select_build_essentials
      selection.select(*CHROOT_TOOLS)
      selection.select(*BUILD_TOOLS)
      selection.select(*@config.get('extra-packages', []))
      selection
    end
    sel = DebPackageSelection.merge(*selections)
    download(sel)
#    puts as_size(@index.size(sel))
#    puts as_size(@index.size_all)
  end
end

app = Application.new.load_sources
app.create_essential_set
app.download_minimal_set


JobQueue.join
