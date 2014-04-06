class Fluent::IkachanOutput < Fluent::Output
  Fluent::Plugin.register_output('ikachan', self)

  # Define `log` method for v0.10.42 or earlier
  unless method_defined?(:log)
    define_method("log") { $log }
  end

  config_param :host, :string, :default => nil
  config_param :port, :integer, :default => 4979
  config_param :base_uri, :string, :default => nil
  config_param :ssl, :bool, :default => nil
  config_param :verify_ssl, :bool, :default => false
  config_param :channel, :string
  config_param :message, :string, :default => nil
  config_param :out_keys, :string, :default => ""
  config_param :privmsg_message, :string, :default => nil
  config_param :privmsg_out_keys, :string, :default => ""
  config_param :time_key, :string, :default => nil
  config_param :time_format, :string, :default => nil
  config_param :tag_key, :string, :default => 'tag'

  def initialize
    super
    require 'net/http'
    require 'uri'
  end

  def configure(conf)
    super

    if @base_uri.nil?
      if @host.nil? or @port.nil?
        raise Fluent::ConfigError, 'If `base_uri is nil, both `host` and `port` must be specifed'
      end
      # if only specifed "ssl true", scheme is https
      scheme = @ssl == true ? "https" : "http"
      @base_uri = "#{scheme}://#{@host}:#{@port}/"
    end

    unless @base_uri =~ /\/$/
      raise Fluent::ConfigError, '`base_uri` must be end `/`'
    end

    # auto enable ssl option by base_uri scheme if ssl is not specifed
    if @ssl.nil?
      @ssl = @base_uri =~ /^https:/ ? true : false
    end

    if ( @base_uri =~ /^https:/ and @ssl == false ) || ( @base_uri =~ /^http:/ and @ssl == true )
      raise Fluent::ConfigError, 'conflict `base_uri` scheme and `ssl`'
    end

    @channel = '#' + @channel

    @join_uri = URI.join(@base_uri, "join")
    @notice_uri = URI.join(@base_uri, "notice")
    @privmsg_uri = URI.join(@base_uri, "privmsg")

    @out_keys = @out_keys.split(',')
    @privmsg_out_keys = @privmsg_out_keys.split(',')

    if @message.nil? and @privmsg_message.nil?
      raise Fluent::ConfigError, "Either 'message' or 'privmsg_message' must be specifed."
    end

    begin
      @message % (['1'] * @out_keys.length) if @message
    rescue ArgumentError
      raise Fluent::ConfigError, "string specifier '%s' and out_keys specification mismatch"
    end

    begin
      @privmsg_message % (['1'] * @privmsg_out_keys.length) if @privmsg_message
    rescue ArgumentError
      raise Fluent::ConfigError, "string specifier '%s' of privmsg_message and privmsg_out_keys specification mismatch"
    end

    if @time_key
      if @time_format
        f = @time_format
        tf = Fluent::TimeFormatter.new(f, true) # IRC notification is formmatted as localtime only...
        @time_format_proc = tf.method(:format)
        @time_parse_proc = Proc.new {|str| Time.strptime(str, f).to_i }
      else
        @time_format_proc = Proc.new {|time| time.to_s }
        @time_parse_proc = Proc.new {|str| str.to_i }
      end
    end
  end

  def start
    res = http_post_request(@join_uri, {'channel' => @channel})
    if res.code.to_i == 200
      # ok
    elsif res.code.to_i == 403 and res.body == "joinned channel: #{@channel}"
      # ok
    else
      raise Fluent::ConfigError, "failed to connect ikachan server #{@host}:#{@port}"
    end
  end

  def shutdown
  end

  def emit(tag, es, chain)
    log.debug "out_ikachan: started  to emit #{tag}"
    started = Time.now
    messages = []
    privmsg_messages = []

    es.each {|time,record|
      messages << evaluate_message(@message, @out_keys, tag, time, record) if @message
      privmsg_messages << evaluate_message(@privmsg_message, @privmsg_out_keys, tag, time, record) if @privmsg_message
    }

    messages.each do |msg|
      begin
        msg.split("\n").each do |m|
          res = http_post_request(@notice_uri, {'channel' => @channel, 'message' => m})
        end
      rescue
        log.warn "out_ikachan: failed to send notice to #{@host}:#{@port}, #{@channel}, message: #{msg}"
      end
    end

    privmsg_messages.each do |msg|
      begin
        msg.split("\n").each do |m|
          res = http_post_request(@privmsg_uri, {'channel' => @channel, 'message' => m})
        end
      rescue
        log.warn "out_ikachan: failed to send privmsg to #{@host}:#{@port}, #{@channel}, message: #{msg}"
      end
    end

    elapsed = (Time.now - started).to_i
    log.debug "out_ikachan: finished to emit #{tag}"
    log.info "out_ikachan\telapsed:#{elapsed}\ttag:#{tag}"
    chain.next
  end

  private

  def evaluate_message(message, out_keys, tag, time, record)
    values = []
    last = out_keys.length - 1

    values = out_keys.map do |key|
      case key
      when @time_key
        @time_format_proc.call(time)
      when @tag_key
        tag
      else
        record[key].to_s
      end
    end

    (message % values).gsub(/\\n/, "\n")
  end

  def http_post_request(uri, params)
    http = Net::HTTP.new(uri.host, uri.port)
    if @ssl
      http.use_ssl = true
      unless @verify_ssl
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
    end
    req = Net::HTTP::Post.new(uri.path)
    req.set_form_data(params)
    http.request req
  end

end
