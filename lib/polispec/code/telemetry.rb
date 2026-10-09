#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    module Telemetry
      @queue = []
      @deferred = false

      class << self
        attr_reader :queue

        def defer!
          @deferred = true
        end

        def emit(type, fields = {})
          if @deferred
            @queue << [type, fields]
          else
            Events.emit(type, fields)
          end
          nil
        end

        def flush
          pending = @queue.dup
          @queue.clear
          @deferred = false
          return if pending.empty?

          $stdout.flush
          return if detach(pending)

          pending.each { |type, fields| Events.emit(type, fields) }
        rescue StandardError
          nil
        end

        private

        def detach(pending)
          return false unless Process.respond_to?(:fork)

          pid = fork do
            begin
              $stdin.reopen(File::NULL)
              $stdout.reopen(File::NULL, "w")
              $stderr.reopen(File::NULL, "w")
              Process.setsid
              pending.each { |type, fields| Events.emit(type, fields) }
            ensure
              exit!(0)
            end
          end
          !pid.nil?
        rescue NotImplementedError, SystemCallError
          false
        end
      end
    end
  end
end
