module Sentry
  module RackInterface
    REQUEST_ID_HEADERS = %w(action_dispatch.request_id HTTP_X_REQUEST_ID).freeze

    def from_rack(env_hash)
      req = ::Rack::Request.new(env_hash)

      self.url = req.scheme && req.url.split('?').first
      self.method = req.request_method
      self.query_string = req.query_string
      self.data = read_data_from(req)
      self.cookies = req.cookies

      self.headers = format_headers_for_sentry(env_hash)
      self.env     = format_env_for_sentry(env_hash)
    end

    private

    # Request ID based on ActionDispatch::RequestId
    def read_request_id_from(env_hash)
      REQUEST_ID_HEADERS.each do |key|
        request_id = env_hash[key]
        return request_id if request_id
      end
      nil
    end

    # See Sentry server default limits at
    # https://github.com/getsentry/sentry/blob/master/src/sentry/conf/server.py
    def read_data_from(request)
      if request.form_data?
        request.POST
      elsif request.body # JSON requests, etc
        data = request.body.read(4096 * 4) # Sentry server limit
        request.body.rewind
        data
      end
    rescue IOError => e
      e.message
    end

    def format_headers_for_sentry(env_hash)
      env_hash.each_with_object({}) do |(key, value), memo|
        begin
          key = key.to_s # rack env can contain symbols
          value = value.to_s
          next memo['X-Request-Id'] ||= read_request_id_from(env_hash) if REQUEST_ID_HEADERS.include?(key)
          next unless key.upcase == key # Non-upper case stuff isn't either

          # Rack adds in an incorrect HTTP_VERSION key, which causes downstream
          # to think this is a Version header. Instead, this is mapped to
          # env['SERVER_PROTOCOL']. But we don't want to ignore a valid header
          # if the request has legitimately sent a Version header themselves.
          # See: https://github.com/rack/rack/blob/028438f/lib/rack/handler/cgi.rb#L29
          next if key == 'HTTP_VERSION' && value == env_hash['SERVER_PROTOCOL']
          next if key == 'HTTP_COOKIE' # Cookies don't go here, they go somewhere else
          next unless key.start_with?('HTTP_') || %w(CONTENT_TYPE CONTENT_LENGTH).include?(key)

          # Rack stores headers as HTTP_WHAT_EVER, we need What-Ever
          key = key.sub(/^HTTP_/, "")
          key = key.split('_').map(&:capitalize).join('-')
          memo[key] = value
        rescue StandardError => e
          # Rails adds objects to the Rack env that can sometimes raise exceptions
          # when `to_s` is called.
          # See: https://github.com/rails/rails/blob/master/actionpack/lib/action_dispatch/middleware/remote_ip.rb#L134
          Sentry.logger.warn(LOGGER_PROGNAME) { "Error raised while formatting headers: #{e.message}" }
          next
        end
      end
    end

    def format_env_for_sentry(env_hash)
      return env_hash if Sentry.configuration.rack_env_whitelist.empty?

      env_hash.select do |k, _v|
        Sentry.configuration.rack_env_whitelist.include? k.to_s
      end
    end
  end

  class HttpInterface
    include RackInterface
  end
end

