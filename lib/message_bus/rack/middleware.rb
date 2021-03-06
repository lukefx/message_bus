# our little message bus, accepts long polling and polling
module MessageBus::Rack; end

class MessageBus::Rack::Middleware

  def self.start_listener
    unless @started_listener

      require 'eventmachine'
      require 'message_bus/em_ext'

      MessageBus.subscribe do |msg|
        if EM.reactor_running?
          EM.next_tick do
            @@connection_manager.notify_clients(msg) if @@connection_manager
          end
        end
      end
      @started_listener = true
    end
  end

  def initialize(app, config = {})
    @app = app
    @@connection_manager = MessageBus::ConnectionManager.new
    self.class.start_listener
  end

  def self.backlog_to_json(backlog)
    m = backlog.map do |msg|
      {
        :global_id => msg.global_id,
        :message_id => msg.message_id,
        :channel => msg.channel,
        :data => msg.data
      }
    end.to_a
    JSON.dump(m)
  end

  def call(env)

    return @app.call(env) unless env['PATH_INFO'] =~ /^\/message-bus\//

    # special debug/test route
    if ::MessageBus.allow_broadcast? && env['PATH_INFO'] == '/message-bus/broadcast'.freeze
        parsed = Rack::Request.new(env)
        ::MessageBus.publish parsed["channel".freeze], parsed["data".freeze]
        return [200,{"Content-Type".freeze => "text/html".freeze},["sent"]]
    end

    if env['PATH_INFO'].start_with? '/message-bus/_diagnostics'.freeze
      diags = MessageBus::Rack::Diagnostics.new(@app)
      return diags.call(env)
    end

    client_id = env['PATH_INFO'].split("/")[2]
    return [404, {}, ["not found"]] unless client_id

    user_id = MessageBus.user_id_lookup.call(env) if MessageBus.user_id_lookup
    group_ids = MessageBus.group_ids_lookup.call(env) if MessageBus.group_ids_lookup
    site_id = MessageBus.site_id_lookup.call(env) if MessageBus.site_id_lookup

    client = MessageBus::Client.new(client_id: client_id, user_id: user_id, site_id: site_id, group_ids: group_ids)

    request = Rack::Request.new(env)
    request.POST.each do |k,v|
      client.subscribe(k, v)
    end

    backlog = client.backlog
    headers = {}
    headers["Cache-Control"] = "must-revalidate, private, max-age=0"
    headers["Content-Type"] ="application/json; charset=utf-8"

    ensure_reactor

    long_polling = MessageBus.long_polling_enabled? &&
                   env['QUERY_STRING'] !~ /dlp=t/.freeze &&
                   EM.reactor_running? &&
                   @@connection_manager.client_count < MessageBus.max_active_clients

    if backlog.length > 0
      [200, headers, [self.class.backlog_to_json(backlog)] ]
    elsif long_polling && env['rack.hijack'] && MessageBus.rack_hijack_enabled?
      io = env['rack.hijack'].call
      client.io = io

      add_client_with_timeout(client)
      [418, {}, ["I'm a teapot, undefined in spec"]]
    elsif long_polling && env['async.callback']

      response = nil
      # load extension if needed
      begin
        response = Thin::AsyncResponse.new(env)
      rescue NameError
        require 'message_bus/rack/thin_ext'
        response = Thin::AsyncResponse.new(env)
      end

      response.headers["Cache-Control"] = "must-revalidate, private, max-age=0".freeze
      response.headers["Content-Type"] ="application/json; charset=utf-8".freeze
      response.status = 200

      client.async_response = response

      add_client_with_timeout(client)

      throw :async
    else
      [200, headers, ["[]"]]
    end
  end

  def ensure_reactor
    # ensure reactor is running
    if EM.reactor_pid != Process.pid
      Thread.new { EM.run }
    end
  end

  def add_client_with_timeout(client)
    @@connection_manager.add_client(client)

    client.cleanup_timer = ::EM::Timer.new(MessageBus.long_polling_interval.to_f / 1000) {
      client.close
      @@connection_manager.remove_client(client)
    }
  end
end

