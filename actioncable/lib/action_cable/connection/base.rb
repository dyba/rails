require 'action_dispatch'

module ActionCable
  module Connection
    # For every WebSocket the Action Cable server accepts, a Connection object will be instantiated. This instance becomes the parent
    # of all of the channel subscriptions that are created from there on. Incoming messages are then routed to these channel subscriptions
    # based on an identifier sent by the Action Cable consumer. The Connection itself does not deal with any specific application logic beyond
    # authentication and authorization.
    #
    # Here's a basic example:
    #
    #   module ApplicationCable
    #     class Connection < ActionCable::Connection::Base
    #       identified_by :current_user
    #
    #       def connect
    #         self.current_user = find_verified_user
    #         logger.add_tags current_user.name
    #       end
    #
    #       def disconnect
    #         # Any cleanup work needed when the cable connection is cut.
    #       end
    #
    #       protected
    #         def find_verified_user
    #           if current_user = User.find_by_identity cookies.signed[:identity_id]
    #             current_user
    #           else
    #             reject_unauthorized_connection
    #           end
    #         end
    #     end
    #   end
    #
    # First, we declare that this connection can be identified by its current_user. This allows us to later be able to find all connections
    # established for that current_user (and potentially disconnect them). You can declare as many
    # identification indexes as you like. Declaring an identification means that an attr_accessor is automatically set for that key.
    #
    # Second, we rely on the fact that the WebSocket connection is established with the cookies from the domain being sent along. This makes
    # it easy to use signed cookies that were set when logging in via a web interface to authorize the WebSocket connection.
    #
    # Finally, we add a tag to the connection-specific logger with name of the current user to easily distinguish their messages in the log.
    #
    # Pretty simple, eh?
    class Base
      include Identification
      include InternalChannel
      include Authorization

      attr_reader :server, :env, :subscriptions, :logger, :worker_pool
      delegate :stream_event_loop, :pubsub, to: :server

      def initialize(server, env)
        @server, @env = server, env

        @worker_pool = server.worker_pool
        @logger = new_tagged_logger

        @websocket      = ActionCable::Connection::WebSocket.new(env, self, stream_event_loop)
        @subscriptions  = ActionCable::Connection::Subscriptions.new(self)
        @message_buffer = ActionCable::Connection::MessageBuffer.new(self)

        @_internal_subscriptions = nil
        @started_at = Time.now
      end

      # Called by the server when a new WebSocket connection is established. This configures the callbacks intended for overwriting by the user.
      # This method should not be called directly -- instead rely upon on the #connect (and #disconnect) callbacks.
      def process # :nodoc:
        logger.info started_request_message

        if websocket.possible? && allow_request_origin?
          respond_to_successful_request
        else
          respond_to_invalid_request
        end
      end

      # Data received over the WebSocket connection is handled by this method. It's expected that everything inbound is JSON encoded.
      # The data is routed to the proper channel that the connection has subscribed to.
      def receive(data_in_json)
        if websocket.alive?
          subscriptions.execute_command ActiveSupport::JSON.decode(data_in_json)
        else
          logger.error "Received data without a live WebSocket (#{data_in_json.inspect})"
        end
      end

      # Send raw data straight back down the WebSocket. This is not intended to be called directly. Use the #transmit available on the
      # Channel instead, as that'll automatically address the correct subscriber and wrap the message in JSON.
      def transmit(data) # :nodoc:
        websocket.transmit data
      end

      # Close the WebSocket connection.
      def close
        websocket.close
      end

      # Invoke a method on the connection asynchronously through the pool of thread workers.
      def send_async(method, *arguments)
        worker_pool.async_invoke(self, method, *arguments)
      end

      # Return a basic hash of statistics for the connection keyed with `identifier`, `started_at`, and `subscriptions`.
      # This can be returned by a health check against the connection.
      def statistics
        {
          identifier: connection_identifier,
          started_at: @started_at,
          subscriptions: subscriptions.identifiers,
          request_id: @env['action_dispatch.request_id']
        }
      end

      def beat
        transmit ActiveSupport::JSON.encode(type: ActionCable::INTERNAL[:message_types][:ping], message: Time.now.to_i)
      end

      def on_open # :nodoc:
        send_async :handle_open
      end

      def on_message(message) # :nodoc:
        message_buffer.append message
      end

      def on_error(message) # :nodoc:
        # ignore
      end

      def on_close(reason, code) # :nodoc:
        send_async :handle_close
      end

      protected
        # The request that initiated the WebSocket connection is available here. This gives access to the environment, cookies, etc.
        def request
          @request ||= begin
            environment = Rails.application.env_config.merge(env) if defined?(Rails.application) && Rails.application
            ActionDispatch::Request.new(environment || env)
          end
        end

        # The cookies of the request that initiated the WebSocket connection. Useful for performing authorization checks.
        def cookies
          request.cookie_jar
        end

        attr_reader :websocket
        attr_reader :message_buffer

      private
        def handle_open
          connect if respond_to?(:connect)
          subscribe_to_internal_channel
          send_welcome_message

          message_buffer.process!
          server.add_connection(self)
        rescue ActionCable::Connection::Authorization::UnauthorizedError
          respond_to_invalid_request
        end

        def handle_close
          logger.info finished_request_message

          server.remove_connection(self)

          subscriptions.unsubscribe_from_all
          unsubscribe_from_internal_channel

          disconnect if respond_to?(:disconnect)
        end

        def send_welcome_message
          # Send welcome message to the internal connection monitor channel.
          # This ensures the connection monitor state is reset after a successful
          # websocket connection.
          transmit ActiveSupport::JSON.encode(type: ActionCable::INTERNAL[:message_types][:welcome])
        end

        def allow_request_origin?
          return true if server.config.disable_request_forgery_protection

          if Array(server.config.allowed_request_origins).any? { |allowed_origin|  allowed_origin === env['HTTP_ORIGIN'] }
            true
          else
            logger.error("Request origin not allowed: #{env['HTTP_ORIGIN']}")
            false
          end
        end

        def respond_to_successful_request
          logger.info successful_request_message
          websocket.rack_response
        end

        def respond_to_invalid_request
          close if websocket.alive?

          logger.error invalid_request_message
          logger.info finished_request_message
          [ 404, { 'Content-Type' => 'text/plain' }, [ 'Page not found' ] ]
        end

        # Tags are declared in the server but computed in the connection. This allows us per-connection tailored tags.
        def new_tagged_logger
          TaggedLoggerProxy.new server.logger,
            tags: server.config.log_tags.map { |tag| tag.respond_to?(:call) ? tag.call(request) : tag.to_s.camelize }
        end

        def started_request_message
          'Started %s "%s"%s for %s at %s' % [
            request.request_method,
            request.filtered_path,
            websocket.possible? ? ' [WebSocket]' : '[non-WebSocket]',
            request.ip,
            Time.now.to_s ]
        end

        def finished_request_message
          'Finished "%s"%s for %s at %s' % [
            request.filtered_path,
            websocket.possible? ? ' [WebSocket]' : '[non-WebSocket]',
            request.ip,
            Time.now.to_s ]
        end

        def invalid_request_message
          'Failed to upgrade to WebSocket (REQUEST_METHOD: %s, HTTP_CONNECTION: %s, HTTP_UPGRADE: %s)' % [
            env["REQUEST_METHOD"], env["HTTP_CONNECTION"], env["HTTP_UPGRADE"]
          ]
        end

        def successful_request_message
          'Successfully upgraded to WebSocket (REQUEST_METHOD: %s, HTTP_CONNECTION: %s, HTTP_UPGRADE: %s)' % [
            env["REQUEST_METHOD"], env["HTTP_CONNECTION"], env["HTTP_UPGRADE"]
          ]
        end
    end
  end
end
