#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "securerandom"
require_relative "editions"
require_relative "state"

module Polispec
  module Web
    GEMS = %w[rack rackup roda webrick].freeze
    VENDOR = File.join(ROOT, "vendor")
    PUBLIC_DIR = File.join(ROOT, "web", "public")

    class Excluded < Polispec::Error
      def code
        "edition_excluded"
      end
    end

    autoload :Auth, File.join(__dir__, "web", "auth")
    autoload :Server, File.join(__dir__, "web", "server")

    Route = Struct.new(:prefix, :mutating, :block)
    Context = Struct.new(:bind, :port, :read_only, :exposed, :auth, :logger, keyword_init: true)

    @routes = {}
    @stop_hooks = []
    @loaded = false
    @context = nil

    class << self
      attr_reader :context

      def context=(value)
        @context = value
      end

      def route(prefix, mutating: false, &block)
        @routes[prefix.to_s] = Route.new(prefix.to_s, mutating, block)
      end

      def routes
        @routes.dup
      end

      def vendor_path(name)
        File.join(VENDOR, name, "lib")
      end

      def dir
        File.join(State.home, "web")
      end

      def ensure_dir
        FileUtils.mkdir_p(dir, mode: 0o700)
        File.chmod(0o700, dir)
        dir
      end

      def ensure_edition!
        raise Excluded, "polispec web is not available in the #{Editions.current} edition" unless Editions.allowed?("web")
      end

      def at_stop(&block)
        @stop_hooks << block
      end

      def stop_hooks
        @stop_hooks.dup
      end

      def load!
        return true if @loaded

        ensure_edition!

        GEMS.reverse_each do |name|
          path = vendor_path(name)
          raise Polispec::Error, "vendored gem #{name} is missing at #{path}" unless File.directory?(path)

          $LOAD_PATH.delete(path)
          $LOAD_PATH.unshift(path)
        end
        silenced do
          GEMS.each { |name| require_gem(name) }
        end
        require_relative "web/app"
        @loaded = true
      end

      def new_request_id
        "req_#{SecureRandom.hex(6)}"
      end

      private

      def require_gem(name)
        require name
      rescue LoadError => e
        raise Polispec::Error, "vendored gem #{name} failed to load: #{e.message}"
      end

      def silenced
        verbose = $VERBOSE
        $VERBOSE = nil
        yield
      ensure
        $VERBOSE = verbose
      end
    end
  end
end
