require 'thread'
require 'terminfo'

class ProgressDisplay
  @@progressdisplay = nil
  def self.start
    @@progressdisplay = ProgressDisplay.new unless @@progressdisplay
    @@progressdisplay
  end

  def initialize
    @mutex = Mutex.new
    @inprogress = []
    @t = STDOUT.isatty ? TermInfo.default_object : nil
    @format_fail = "[" + _red("FAIL") + "] %s"
    @format_done = "[" + _green("DONE") + "] %s"
    @format_progress = "[" + _yellow("%3i%%") + "] %s"
    if !@t.nil?
      $stdout = new_logger
      $stderr = new_logger if STDERR.isatty
    end
  end

  def new(title)
    @mutex.synchronize do
      obj = { :finished => false, :current => 0, :title => title, :failed => false }
      @inprogress << obj
      if !@t.nil?
        @t.io.puts
        _redraw(@inprogress.index(obj))
      end
      return ProgressItem.new(self, obj)
    end
  end

  def log(msg)
    @mutex.synchronize do
      msglines = msg.split(/ *[\r\n]+/)
      return if msglines.empty?
      if @t.nil?
        STDOUT.puts msglines
      elsif @inprogress.empty?
        msglines.each { |line| @t.io.write line + "\n" }
      else
        linelimit = @t.screen_columns
        lines = [@inprogress.length, @t.screen_lines - 1].min
        @t.write(
          @t.control_string('cr') +
          @t.control_string(lines, 'cuu', lines) +
          @t.control_string(lines, 'ed'))
        msglines.each { |line| @t.io.write line + "\n" }
        @inprogress[-lines..-1].each do |item|
          @t.io.write _item_to_s(item, linelimit) + "\n"
        end
      end
    end
  end

  def new_logger
    return ProgressDisplayLog.new(self)
  end

  def _update(obj)
    @mutex.synchronize do
      index = @inprogress.index(obj)
      return if index.nil?

      if obj[:finished] then
        @inprogress.delete_at(index)
        @inprogress.unshift(obj)
        _redraw
        @inprogress.shift
      else
        _redraw(index)
      end
    end
  end

  def _redraw(index = nil)
    if !@t.nil?
      linelimit = @t.screen_columns
      lines = [@inprogress.length, @t.screen_lines - 1].min
      if index
        goup = @inprogress.length - index
        return if goup > lines
        @t.write(
          @t.control_string('cr') +
          @t.control_string(goup, 'cuu', goup) +
          @t.control_string(lines, 'el'))
        @t.io.write _item_to_s(@inprogress[index], linelimit)
        @t.control('cr')
        @t.control(goup, 'cud', goup)
      else
        @t.write(
          @t.control_string('cr') +
          @t.control_string(lines, 'cuu', lines) +
          @t.control_string(lines, 'ed'))
        @inprogress[-lines..-1].each do |item|
          @t.io.write _item_to_s(item, linelimit) + "\n"
        end
      end
    else
      # only print finished items
      @inprogress.each do |item|
        if item[:finished] then
          puts _item_to_s(item)
        end
      end
    end
  end

  def _color(c, s)
    return s if @t.nil?
    return @t.control_string('setf', c) + s + @t.control_string('setf', 7)
  end

  def _bgcolor(c, s)
    return s if @t.nil?
    return @t.control_string('setb', c) + s + @t.control_string('setb', 0)
  end

  def _red(s) _color(4, s) end
  def _green(s) _color(2, s) end
  def _yellow(s) _color(6, s) end
  def _bggreen(s) _bgcolor(2, s) end

  def _bgprogres(s, length, progress)
    return s if length.nil? || @t.nil?
    s = s[0..length-1]
    s = s + ' ' * (length - s.length)
    at = (progress.to_f * length / 100.0).to_i
    return s if 0 >= at
    _bggreen(s[0..at-1]) + s[at..-1].to_s
  end

  def _item_to_s(item, linelimit = nil)
    linelimit -= 7 if !linelimit.nil?
    title = item[:title]
    title = "#{title}: #{item[:failed_msg]}" if item[:failed]
    title = title[0..linelimit-1] if !linelimit.nil?
    return @format_fail % title if item[:failed]
    return @format_done % title if item[:finished]
    return @format_progress % [item[:current], _bgprogres(title, linelimit, item[:current])]
  end

  class ProgressItem
    def initialize(display, object)
      @display = display
      @object = object
    end

    def update(state, autofinish = true) # 0.0 .. 1.0
      return if @object[:finished]
      state = [[(state.to_f * 100).to_i, 100].min, 0].max
      return if @object[:current] == state && (state < 100 || !autofinish)
      @object[:current] = state
      @object[:finished] = true if autofinish && state >= 100
      @display._update(@object)
    end

    def finish(msg = nil)
      return if @object[:finished]
      @object[:title] = "#{@object[:title]} (#{msg})" if !msg.to_s.empty?
      @object[:finished] = true
      @object[:current] = 100
      @display._update(@object)
    end

    def failed(msg = nil)
      return if @object[:finished]
      @object[:failed] = true
      @object[:failed_msg] = msg.to_s
      finish
    end

    def to_s
      @display._item_to_s(@object)
    end

    def title
      @object[:title]
    end
  end
end

class ProgressDisplayLog
  def initialize(pd)
    @buf = ""
    @pd = pd
    @closed = false
    @mutex = Mutex.new
  end

  def binmode
  end

  def binmode?
    true
  end

  def close
    return if @closed
    @closed = true
    msg = @buf
    @buf = ""
    @pd.log(msg)
  end

  def close_read
  end

  def close_write
    close
  end

  def closed?
    @closed
  end

  def closed_read?
    true
  end

  def closed_write?
    @closed
  end

  def codepoints(*args, &block)
    each_codepoint(*args, &block)
  end

  def _empty_each(*args, &block)
    return [].to_enum if block.nil?
    nil
  end

  alias :each :_empty_each
  alias :each_line :_empty_each
  alias :each_byte :_empty_each
  alias :each_char :_empty_each
  alias :each_codepoint :_empty_each

  alias :bytes :each_byte
  alias :chars :each_char
  alias :codepoints :each_codepoint
  alias :lines :each_line

  def eof?
    true
  end
  alias :eof :eof?

  def external_encoding
    TermInfo.default_object.io.encoding
  end

  def flush
  end

  def getbyte
    nil
  end

  def getc
    nil
  end

  def gets(*args)
    nil
  end

  def internal_encoding
    TermInfo.default_object.io.encoding
  end

  def tty?
    false
  end
  alias :isatty tty?

  def print(*objs)
    if objs.empty?
      write $_
    else
      write objs.shift
      while !objs.empty?
        write $, unless $,.nil?
        write objs.shift
      end
      write $\ unless $\.nil?
    end
    nil
  end

  def printf(format, *args)
    write sprintf(format, *args)
    nil
  end

  def putc(c)
    if c.is_a? String
      write(c[0])
    else
      printf("%c", c)
    end
    c
  end

  def puts(*args)
    if args.empty?
      write "\n"
      return nil
    end
    args.each do |arg|
      if (!arg.is_a? String) && (arg.respond_to? :each) && (arg.respond_to? :empty?)
        puts *arg unless arg.empty?
      else
        arg = arg.to_s
        arg += "\n" unless arg[-1] == "\n"
        write arg
      end
    end
  end

  def read(*args)
    nil
  end
  def read_nonblock(*args)
    raise EOFError
  end

  def read_byte
    raise EOFError
  end

  def read_char
    raise EOFError
  end

  def read_line(*args)
    raise EOFError
  end

  def read_lines(*args)
    raise EOFError
  end

  def read_partial(*args)
    raise EOFError
  end

  def write(chunk)
    match = nil
    @mutex.synchronize do
      @buf += chunk.to_s
      match = /^(.*\n)?(.*)$/.match(@buf)
      @buf = match[2]
      @pd.log(match[1]) unless match[1].nil?
    end
  end
  alias :<< :write
end
