# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

require 'new_relic/agent/instrumentation/controller_instrumentation'

module NewRelic
  module Agent
    module Instrumentation
      # == Instrumentation for Rack
      #
      # New Relic will instrument a #call method as if it were a controller
      # action, collecting transaction traces and errors.  The middleware will
      # be identified only by its class, so if you want to instrument multiple
      # actions in a middleware, you need to use
      # NewRelic::Agent::Instrumentation::ControllerInstrumentation::ClassMethods#add_transaction_tracer
      #
      # Example:
      #   require 'newrelic_rpm'
      #   require 'new_relic/agent/instrumentation/rack'
      #   class Middleware
      #     def call(env)
      #       ...
      #     end
      #     # Do the include after the call method is defined:
      #     include NewRelic::Agent::Instrumentation::Rack
      #   end
      #
      # == Instrumenting Metal and Cascading Middlewares
      #
      # Metal apps and apps belonging to Rack::Cascade middleware
      # follow a convention of returning a 404 for all requests except
      # the ones they are set up to handle.  This means that New Relic
      # needs to ignore these calls when they return a 404.
      #
      # In these cases, you should not include or extend the Rack
      # module but instead include
      # NewRelic::Agent::Instrumentation::ControllerInstrumentation.
      # Here's how that might look for a Metal app:
      #
      #   require 'new_relic/agent/instrumentation/controller_instrumentation'
      #   class MetalApp
      #     extend NewRelic::Agent::Instrumentation::ControllerInstrumentation
      #     def self.call(env)
      #       if should_do_my_thing?
      #         perform_action_with_newrelic_trace(:category => :rack) do
      #           return my_response(env)
      #         end
      #       else
      #         return [404, {"Content-Type" => "text/html"}, ["Not Found"]]
      #       end
      #     end
      #   end
      #
      # == Overriding the metric name
      #
      # By default the middleware is identified only by its class, but if you want to
      # be more specific and pass in name, then omit including the Rack instrumentation
      # and instead follow this example:
      #
      #   require 'newrelic_rpm'
      #   require 'new_relic/agent/instrumentation/controller_instrumentation'
      #   class Middleware
      #     include NewRelic::Agent::Instrumentation::ControllerInstrumentation
      #     def call(env)
      #       ...
      #     end
      #     add_transaction_tracer :call, :category => :rack, :name => 'my app'
      #   end
      #
      # @api public
      #
      module Rack
        include ControllerInstrumentation

        def newrelic_request_headers
          @newrelic_request.env
        end

        def call_with_newrelic(*args)
          @newrelic_request = ::Rack::Request.new(args.first)
          perform_action_with_newrelic_trace(:category => :rack, :request => @newrelic_request) do
            result = call_without_newrelic(*args)
            # Ignore cascaded calls
            Transaction.abort_transaction! if result.first == 404
            result
          end
        end

        def self.included middleware #:nodoc:
          middleware.class_eval do
            alias call_without_newrelic call
            alias call call_with_newrelic
          end
        end

        def self.extended middleware #:nodoc:
          middleware.class_eval do
            class << self
              alias call_without_newrelic call
              alias call call_with_newrelic
            end
          end
        end
      end
    end
  end
end

DependencyDetection.defer do
  named :rack

  depends_on do
    defined?(::Rack) && defined?(::Rack::Builder)
  end

  executes do
    ::NewRelic::Agent.logger.info 'Installing deferred Rack instrumentation'
  end

  executes do
    class ::Rack::Builder
      class << self
        attr_accessor :_nr_deferred_detection_ran
      end
      self._nr_deferred_detection_ran = false

      def to_app_with_newrelic_deferred_dependency_detection
        @use = add_new_relic_tracing_to_middlewares(@use)

        unless Rack::Builder._nr_deferred_detection_ran
          NewRelic::Agent.logger.info "Doing deferred dependency-detection before Rack startup"
          DependencyDetection.detect!
          Rack::Builder._nr_deferred_detection_ran = true
        end

        result = to_app_without_newrelic

        result.class.class_eval do
          include NewRelic::Agent::Instrumentation::Rack
        end

        result
      end

      def add_new_relic_tracing_to_middlewares(middlewares)
        middlewares.map do |middleware|
          Proc.new do |app|
            result = middleware.call(app)

            klass = result.class
            add_new_relic_tracing_to_middleware(klass)

            result
          end
        end
      end

      def add_new_relic_tracing_to_middleware(middleware_class)
        klass = Kernel.const_get(middleware_class.to_s)
        new_call = Proc.new do |env|
          class << self
            include ::NewRelic::Agent::MethodTracer
          end

          trace_execution_scoped("Middleware/Rack/#{middleware_class}") do
            call_without_new_relic_tracing(env)
          end
        end

        klass.send(:define_method, :call_with_new_relic_tracing, new_call)
        klass.send(:alias_method, :call_without_new_relic_tracing, :call)
        klass.send(:alias_method, :call, :call_with_new_relic_tracing)
      end

      alias_method :to_app_without_newrelic, :to_app
      alias_method :to_app, :to_app_with_newrelic_deferred_dependency_detection
    end
  end
end
