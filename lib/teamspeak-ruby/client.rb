require 'socket'

module Teamspeak
  class Client
    # Should commands be throttled? Default is true
    attr_writer(:flood_protection)
    # Number of commands within flood_time before pausing. Default is 10
    attr_writer(:flood_limit)
    # Length of time before flood_limit is reset in seconds. Default is 3
    attr_writer(:flood_time)
    # access the raw socket
    attr_reader(:sock)

    # First is escaped char, second is real char.
    SPECIAL_CHARS = [
      ['\\\\', '\\'],
      ['\\/', '/'],
      ['\\s', ' '],
      ['\\p', '|'],
      ['\\a', '\a'],
      ['\\b', '\b'],
      ['\\f', '\f'],
      ['\\n', '\n'],
      ['\\r', '\r'],
      ['\\t', '\t'],
      ['\\v', '\v']
    ].freeze

    # Initializes Client
    #
    #   connect('voice.domain.com', 88888)
    def initialize(host = 'localhost', port = 10_011)
      connect(host, port)

      # Throttle commands by default unless connected to localhost
      @flood_protection = true unless host
      @flood_limit = 10
      @flood_time = 3

      @flood_timer = Time.new
      @flood_current = 0
    end

    # Connects to a TeamSpeak 3 server
    #
    #   connect('voice.domain.com', 88888)
    def connect(host = 'localhost', port = 10_011)
      @sock = TCPSocket.new(host, port)

      # Check if the response is the same as a normal teamspeak 3 server.
      response = @sock.gets.strip
      if response != 'TS3'
        out = []
        data = {}
        response.split(' ').each do |key|
          value = key.split('=', 2)

          data[value[0]] = decode_param(value[1])
        out.push(data)
        end

        id = out.first['id'] || 0
        message = out.first['msg'] || 0
        extra_message = out.first['extra_msg'] || 'none'

        msg = "\r\nID=#{id}\r\nMESSAGE=#{message}\r\nEXTRA_MESSAGE=#{extra_message}"
        raise InvalidServer, msg unless out == 'TS3'
      end

      # Remove useless text from the buffer.
      @sock.gets
    end

    # Disconnects from the TeamSpeak 3 server
    def disconnect
      @sock.puts 'quit'
      @sock.close
    end

    # Authenticates with the TeamSpeak 3 server
    #
    #   login('serveradmin', 'H8YlK1f9')
    def login(user, pass, sid = nil, name = nil)
      command('login', client_login_name: user, client_login_password: pass)
      use(sid) unless sid == nil
      rename(name) unless name == nil
    end

    # Say to the query to use the given sid
    #
    #   use(1)
    def use(sid)
      command('use', sid: sid)
    end

    # Renames the query client
    #
    #   rename('Server Bot')
    def rename(new_name)
      command('clientupdate', client_nickname: new_name)
    end

    # Returns info about the server
    #
    #   serverinfo()
    def serverinfo()
      command('serverinfo')
    end

    # Returns info about the host
    #
    #   hostinfo()
    def hostinfo()
      command('hostinfo')
    end

    # Returns info about the current instance
    #
    #   instanceinfo()
    def instanceinfo()
      command('instanceinfo')
    end

    # Gets a client by his name
    #
    #   getclient('TriiNoxYs')
    def getclient(name)
      clients = command('clientfind', pattern: name)
      clients.each { |client| return clientinfo(clid: client['clid']) if client['client_nickname'] == name }
    end

    # Returns the clients list
    #
    #   clientlist()
    def clientlist()
      command('clientlist')
    end
    alias_method :clients, :clientlist

    # Returns info about a client
    #
    #   clientinfo(clid: 6)
    def clientinfo(params = {})
      check_error([:clid], params)

      command('clientinfo', clid: params[:clid])
    end

    # Moves a client
    #
    #   clientmove(clid: 6, cid: 1, cpw: 'pass')
    def clientmove(params = {})
      check_error([:clid, :cid], params, [:cpw])

      command('clientmove', clid: params[:clid], cid: params[:cid], cpw: params[:cpw])
    end

    # Sends a poke to a client
    #
    #   clientpoke(clid: 6, msg: "This is a poke")
    def clientpoke(params = {})
      check_error([:clid, :msg], params)

      command('clientpoke', clid: params[:clid], msg: params[:msg])
    end

    # Sends a message to a client
    #
    #   clientmessage(clid: 6, msg: "This is a message")
    def clientmessage(params = {})
      check_error([:clid, :msg], params)

      command('sendtextmessage', targetmode: 1, target: params[:clid], msg: params[:msg])
    end

    # Sends a message to the server
    #
    #   servermessage(msg: "This is a server message")
    def servermessage(params = {})
      check_error([:msg], params)

      command('sendtextmessage', targetmode: 3, target: command('serverinfo')['virtualserver_id'], msg: params[:msg])
    end

    # Sends a message to all clients
    #
    #   globalmessage(msg: "This is a global message")
    def globalmessage(params = {})
      check_error([:msg], params)

      command('gm', msg: params[:msg])
    end

    # Kicks a client from channel
    #
    #   clientkick_from_channel(clid: 6, msg: "Kicked from channel!")
    def clientkick_from_channel(params = {})
      check_error([:clid], params, [:msg])

      command('clientkick', reasonid: 4, clid: params[:clid], reasonmsg: params[:msg])
    end

    # Kicks a client from server
    #
    #   clientkick_from_server(clid: 6, msg: "Kicked from server!")
    def clientkick_from_server(params = {})
      check_error([:clid], params, [:msg])

      command('clientkick', reasonid: 5, clid: params[:clid], reasonmsg: params[:msg])
    end

    # Sends command to the TeamSpeak 3 server and returns the response
    #
    #   command('use', {'sid' => 1}, '-away')
    def command(cmd, params = {}, options = '')
      flood_control

      out = ''
      response = ''

      out += cmd

      params.each_pair do |key, value|
        out += " #{key}=#{encode_param(value.to_s)}"
      end

      out += ' ' + options

      @sock.puts out

      if cmd == 'servernotifyregister'
        2.times { response += @sock.gets }
        return parse_response(response)
      end

      loop do
        response += @sock.gets

        break if response.index(' msg=')
      end

      # Array of commands that are expected to return as an array.
      # Not sure - clientgetids
      should_be_array = %w(
        bindinglist serverlist servergrouplist servergroupclientlist
        servergroupsbyclientid servergroupclientlist logview channellist
        channelfind channelgrouplist channelgroupclientlist channelgrouppermlist
        channelpermlist clientlist clientfind clientdblist clientdbfind
        channelclientpermlist permissionlist permoverview privilegekeylist
        messagelist complainlist banlist ftlist custominfo permfind
      )

      parsed_response = parse_response(response)

      should_be_array.include?(cmd) ? parsed_response : parsed_response.first
    end

    def parse_response(response)
      out = []

      response.split('|').each do |key|
        data = {}

        key.split(' ').each do |inner_key|
          value = inner_key.split('=', 2)

          data[value[0]] = decode_param(value[1])
        end

        out.push(data)
      end

      check_response_error(out)

      out
    end

    def decode_param(param)
      return nil unless param
      # Return as integer if possible
      return param.to_i if param.to_i.to_s == param

      SPECIAL_CHARS.each do |pair|
        param = param.gsub(pair[0], pair[1])
      end

      param
    end

    def encode_param(param)
      SPECIAL_CHARS.each do |pair|
        param = param.gsub(pair[1], pair[0])
      end

      param
    end

    def check_response_error(response)
      id = response.first['id'] || 0
      message = response.first['msg'] || 0

      raise ServerError.new(id, message) unless id == 0
    end

    def flood_control
      if @flood_protection
        @flood_current += 1

        flood_time_reached = Time.now - @flood_timer < @flood_time
        flood_limit_reached = @flood_current == @flood_limit

        sleep(@flood_time) if flood_time_reached && flood_limit_reached

        if flood_limit_reached
          # Reset flood protection
          @flood_timer = Time.now
          @flood_current = 0
        end
      end
    end

    def check_error(mandatory, params, optional = [])
      raise ArgumentError, "Wrong numer of arguments (#{params.keys.size} for #{mandatory.size})" unless params.keys.size >= mandatory.size
      mandatory.each { |param| raise ArgumentError, "Missing argument :#{param}" unless params.has_key? param }
      params.each_key { |param| raise ArgumentError, "Unknow argument :#{param}" unless (mandatory+optional).include? param }
    end

    private(
      :parse_response, :decode_param, :encode_param,
      :check_error, :check_response_error, :flood_control
    )
  end
end
