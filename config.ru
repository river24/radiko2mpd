# coding: utf-8
require 'uri'
require 'logger'
require 'net/http'
require 'sinatra'
require 'sinatra/streaming'
require 'open3'

# icecast2 uri
icecast2_uri = URI.parse("http://#{ENV['ICECAST2_ADDR']}:#{ENV['ICECAST2_PORT']}#{ENV['ICECAST2_PATH']}")

# radio command
radio_script=::File.dirname(__FILE__) + "/scripts/radio.bash"
stop_command="#{radio_script} stop"
state_command="#{radio_script} state"

# logger
AppLogger = ::Logger.new(::File.dirname(__FILE__) + "/log/app.log")
AppLogger.level = 0

rack_logger = ::Logger.new(::File.dirname(__FILE__) + "/log/rack.log")
rack_logger.instance_eval do
  alias :write :'<<'
end
use Rack::CommonLogger, rack_logger

# helper for logger
helpers do
  def logger
    if defined?(AppLogger)
      AppLogger
    else
      env['rack.logger']
    end
  end
end

get "/:station" do
  target_station = params[:station].to_s

  path = icecast2_uri.path.dup
  path << "?" << icecast2_uri.query if icecast2_uri.query
  request_headers = request.env.select { |k, v| k.start_with?('HTTP_') }

  # 停止
  system(stop_command)
  logger.info("Stop: initiation")

  # icecast2停止確認
  loop_count = 10
  count = 0
  while count < loop_count
    server = nil
    server = Net::BufferedIO.new(TCPSocket.new(icecast2_uri.host, icecast2_uri.port))

    server.writeline "GET #{path} HTTP/1.0"
    server.writeline ""

    proxy_response = Net::HTTPResponse.read_new(server)
    server.close
    if proxy_response.code.to_i == 404
      logger.info("Icecast2 returns 404")
      break
    end

    logger.info("Waiting for 404 from Icecast2 (loop:#{count})")
    sleep 1
    count = count + 1
  end

  # 再生
  play_command="#{radio_script} play #{target_station} > /dev/null 2>&1 &"
  system(play_command)
  logger.info("Play: channel '#{target_station}'")

  sleep 1

  on_air_flag = false
  on_air_pid_array = []

  loop_count = 10
  count = 0
  while count < loop_count
    state_output, state_error, state_status = Open3.capture3(state_command)
    state_output.split("\n").each do |pid|
      on_air_pid_array.push(pid)
    end

    if on_air_pid_array.size > 0
      logger.info("ON AIR PIDs: #{on_air_pid_array}")
      break
    end

    logger.info("Waiting for VLC starting")
    sleep 1
    count = count + 1
  end

  # icecast2再生確認
  loop_count = 10
  count = 0
  while count < loop_count
    server = nil
    server = Net::BufferedIO.new(TCPSocket.new(icecast2_uri.host, icecast2_uri.port))

    server.writeline "GET #{path} HTTP/1.0"
    server.writeline ""

    proxy_response = Net::HTTPResponse.read_new(server)
    server.close
    if proxy_response.code.to_i == 200
      on_air_flag = true
      logger.info("Icecast2 returns 200")
      break
    end

    logger.info("Waiting for 200 from Icecast2 (loop:#{count})")
    sleep 1
    count = count + 1
  end

  if on_air_pid_array.size > 0
    on_air_continue = false

    state_output, state_error, state_status = Open3.capture3(state_command)
    state_output.split("\n").each do |pid|
      if on_air_pid_array.include?(pid)
        on_air_continue = true
      end
    end

    if !on_air_continue
      break
    end

    server = nil
    server = Net::BufferedIO.new(TCPSocket.new(icecast2_uri.host, icecast2_uri.port))

    server.writeline "GET #{path} HTTP/1.0"
    request_headers.each do |k, v|
      server.writeline "#{k}: #{v}"
    end
    server.writeline ""

    proxy_response = Net::HTTPResponse.read_new(server)
    response.status = proxy_response.code.to_i
    proxy_response.each do |k, v|
      headers[k] = v
    end

    stream do |out|
      while true  do
        begin
          block=''
          server.read(4096, block)
        rescue EOFError => e
          break
        ensure
          if out.closed?
            server.close
            on_air_pid_array.each do |on_air_pid|
              # Process.kill("KILL", on_air_pid.to_i)
              kill_command="kill -KILL #{on_air_pid.to_i}"
              system(kill_command)
            end
            logger.info("Stop: client disconnected")
            break
          else
            out << block unless out.closed?
          end
          if block=='' then
            break
          end
        end
      end
    end
  end

  if on_air_pid_array.size == 0
    response.status = 404
  end
end

after do
  cache_control :no_cache
end

run Sinatra::Application

