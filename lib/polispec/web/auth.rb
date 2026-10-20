#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "openssl"
require "securerandom"
require "time"

module Polispec
  module Web
    class Auth
      CODE_TTL = 120
      SESSION_IDLE = 12 * 3600
      MUTATION_LIMIT = 30
      MUTATION_WINDOW = 60
      SESSION_CAP = 64
      COOKIE = "ps_session"
      CODE_FORMAT = /\A([0-9a-f]{16})\.(\d{1,12})\.([0-9a-f]{32})\z/.freeze

      Session = Struct.new(:token, :csrf, :created_at, :last_seen, :mutations)

      def self.secret_path
        File.join(Web.dir, "launch.secret")
      end

      def self.load_secret
        path = secret_path
        Web.ensure_dir
        create_secret(path) unless File.exist?(path)
        File.read(path).strip
      end

      def self.create_secret(path)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write("#{SecureRandom.hex(32)}\n") }
      rescue Errno::EEXIST
        nil
      end

      def self.mint(secret, now = Time.now.to_i)
        nonce = SecureRandom.hex(8)
        expiry = now + CODE_TTL
        "#{nonce}.#{expiry}.#{sign(secret, nonce, expiry)}"
      end

      def self.sign(secret, nonce, expiry)
        OpenSSL::HMAC.hexdigest("SHA256", secret, "#{nonce}.#{expiry}")[0, 32]
      end

      def self.equal?(left, right)
        left = left.to_s
        right = right.to_s
        return false unless left.bytesize == right.bytesize

        left.bytes.zip(right.bytes).reduce(0) { |acc, (a, b)| acc | (a ^ b) }.zero?
      end

      def initialize(secret:)
        @secret = secret
        @used = {}
        @sessions = {}
        @lock = Mutex.new
      end

      def mint(now = Time.now.to_i)
        self.class.mint(@secret, now)
      end

      def exchange(code, now = Time.now.to_i)
        match = CODE_FORMAT.match(code.to_s)
        return nil unless match

        nonce, expiry, mac = match.captures
        return nil unless self.class.equal?(self.class.sign(@secret, nonce, expiry), mac)
        return nil if expiry.to_i < now

        @lock.synchronize do
          prune(now)
          return nil if @used.key?(nonce)

          @used[nonce] = expiry.to_i
          open_session(now)
        end
      end

      def lookup(token, now = Time.now.to_f)
        return nil if token.to_s.empty?

        @lock.synchronize do
          session = @sessions[token.to_s]
          return nil unless session

          if now - session.last_seen > SESSION_IDLE
            @sessions.delete(token.to_s)
            return nil
          end
          session.last_seen = now
          session
        end
      end

      def close(token)
        @lock.synchronize { @sessions.delete(token.to_s) }
      end

      def expires_at(session)
        Time.at(session.last_seen + SESSION_IDLE).utc.iso8601
      end

      def take_mutation(session, now = Time.now.to_f)
        @lock.synchronize do
          session.mutations.reject! { |stamp| now - stamp >= MUTATION_WINDOW }
          if session.mutations.length >= MUTATION_LIMIT
            wait = (MUTATION_WINDOW - (now - session.mutations.first)).ceil
            return [false, [wait, 1].max]
          end
          session.mutations << now
          [true, 0]
        end
      end

      def session_count
        @lock.synchronize { @sessions.length }
      end

      private

      def open_session(now)
        @sessions.delete(@sessions.min_by { |_, item| item.last_seen }.first) while @sessions.length >= SESSION_CAP
        session = Session.new(SecureRandom.hex(32), SecureRandom.hex(32), now.to_f, now.to_f, [])
        @sessions[session.token] = session
        session
      end

      def prune(now)
        @used.delete_if { |_, expiry| expiry < now }
        @sessions.delete_if { |_, item| now - item.last_seen > SESSION_IDLE }
      end
    end
  end
end
