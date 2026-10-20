#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "digest"
require "ipaddr"
require "roda"
require_relative "../delegate"
require_relative "../delegate/grants"
require_relative "../effect"
require_relative "../description"
require_relative "../registration"
require_relative "auth"

module Polispec
  module Web
    class App < Roda
      CSP = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
      SAFE = %w[GET HEAD].freeze
      COMPUTE = %w[lint explain explain-text blast-radius].freeze
      MAX_BODY = 2 * 1024 * 1024
      MIME = {
        ".html" => "text/html; charset=utf-8",
        ".js" => "text/javascript; charset=utf-8",
        ".mjs" => "text/javascript; charset=utf-8",
        ".css" => "text/css; charset=utf-8",
        ".json" => "application/json",
        ".webmanifest" => "application/manifest+json",
        ".svg" => "image/svg+xml",
        ".png" => "image/png",
        ".jpg" => "image/jpeg",
        ".jpeg" => "image/jpeg",
        ".webp" => "image/webp",
        ".gif" => "image/gif",
        ".ico" => "image/x-icon",
        ".woff2" => "font/woff2",
        ".woff" => "font/woff",
        ".txt" => "text/plain; charset=utf-8",
        ".yml" => "application/yaml",
        ".yaml" => "application/yaml"
      }.freeze
      HOST_FORMAT = /\A(\[[0-9a-fA-F:.]+\]|[A-Za-z0-9.-]+)(?::(\d+))?\z/.freeze

      plugin :default_headers,
             "Content-Security-Policy" => CSP,
             "X-Content-Type-Options" => "nosniff",
             "Referrer-Policy" => "no-referrer"
      plugin :hash_branches
      plugin :all_verbs
      plugin :json, classes: [Array, Hash]
      plugin :json_parser,
             content_type_regexp: %r{\Aapplication/json\b}i,
             error_handler: proc { |r| r.scope.fail!(400, "bad_json", "the request body is not valid JSON") }
      plugin :error_handler do |error|
        Web.context&.logger&.error("#{request_id} #{error.class}: #{error.message}")
        response["X-Request-Id"] = request_id
        fail!(500, "server", "internal error")
      end

      route do |r|
        @request_id = Web.new_request_id
        response["X-Request-Id"] = @request_id
        guard_host(r)
        guard_size(r)
        r.on "api", "v1" do
          response["Cache-Control"] = "no-store"
          guard_api(r)
          r.hash_branches(:api)
          fail!(404, "not_found", "no such route")
        end
        serve_static(r)
      end

      attr_reader :request_id

      def fail!(status, kind, message, extra = {})
        payload = { "error" => kind, "message" => message }.merge(extra.each_with_object({}) { |(k, v), memo| memo[k.to_s] = v })
        payload["request_id"] = request_id
        response.status = status
        response["Content-Type"] = "application/json"
        response["Retry-After"] = extra[:retry_after].to_s if extra[:retry_after]
        payload.delete("retry_after")
        response.write(JSON.generate(payload))
        request.halt
      end

      def disabled!(reason)
        fail!(403, "disabled", reason.to_s, reason: reason.to_s)
      end

      def auth
        Web.context.auth
      end

      def current_session
        @current_session
      end

      def session_payload(session)
        { "csrf" => session.csrf, "expires_at" => auth.expires_at(session) }
      end

      def set_session_cookie(token)
        response["Set-Cookie"] = "#{Auth::COOKIE}=#{token}; HttpOnly; SameSite=Strict; Path=/"
      end

      def clear_session_cookie
        response["Set-Cookie"] = "#{Auth::COOKIE}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0"
      end

      def config_payload
        {
          "version" => Polispec.version,
          "edition" => Editions.current,
          "epoch" => epoch,
          "theme" => Engine::Settings.web_theme,
          "operator" => Engine::Settings.operator,
          "owner" => Registration.owner,
          "home" => Dir.home,
          "flags" => {
            "author" => author_flag,
            "feed" => { "enabled" => true, "reason" => nil },
            "description" => description_flag,
            "delegate" => delegate_flag
          }
        }
      end

      private

      def epoch
        Polispec::Effect.epoch
      rescue StandardError
        nil
      end

      def description_flag
        strict = Engine::Settings.description_strict?
        if Polispec::Description.ahead_of_runtime?
          { "allowed" => false, "reason" => "the installed release is older than 0.34.0; readers of a rulebook with a description would reject it", "strict" => strict }
        else
          { "allowed" => true, "reason" => nil, "strict" => strict }
        end
      rescue StandardError
        { "allowed" => false, "reason" => "the description state could not be read", "strict" => false }
      end

      def author_flag
        if !Editions.allowed?("author")
          { "enabled" => false, "reason" => "the #{Editions.current} edition excludes the author" }
        elsif !Engine::Settings.author_enabled?
          { "enabled" => false, "reason" => "polispec.author.enabled is off" }
        else
          { "enabled" => true, "reason" => nil }
        end
      rescue StandardError
        { "enabled" => false, "reason" => "the author state could not be read" }
      end

      def delegate_flag
        grant = Polispec::Delegate::Grants.find("polispec-web")
        verbs = Array(grant && grant["verbs"]).map(&:to_s).select { |verb| verb.start_with?("exceptions-") }
        { "runner_up" => File.socket?(Polispec::Delegate.socket_path), "granted_verbs" => verbs }
      rescue StandardError
        { "runner_up" => false, "granted_verbs" => [] }
      end

      def allowed_host?(header)
        match = HOST_FORMAT.match(header.to_s)
        return false unless match

        context = Web.context
        return false unless (match[2] || "80").to_i == context.port

        name = match[1].downcase
        return true if name == "localhost"
        return true if name == bracketed(context.bind)
        return true if context.exposed && wildcard?(context.bind) && ip_literal?(name)

        false
      end

      def bracketed(address)
        text = address.to_s.downcase
        text.include?(":") ? "[#{text}]" : text
      end

      def wildcard?(address)
        ["0.0.0.0", "::"].include?(address.to_s)
      end

      def ip_literal?(name)
        IPAddr.new(name.delete("[]"))
        true
      rescue IPAddr::Error
        false
      end

      def allowed_origin?(origin)
        match = %r{\Ahttp://(.+)\z}.match(origin.to_s)
        !match.nil? && allowed_host?(match[1])
      end

      def guard_host(r)
        return if allowed_host?(r.env["HTTP_HOST"])

        fail!(403, "forbidden", "the Host header does not name this server")
      end

      def guard_size(r)
        length = r.env["CONTENT_LENGTH"].to_i
        fail!(413, "too_large", "the request body is larger than #{MAX_BODY} bytes") if length > MAX_BODY
      end

      def guard_api(r)
        method = r.request_method
        path = r.remaining_path.sub(%r{/+\z}, "")
        if method == "POST" && path == "/session"
          origin = r.env["HTTP_ORIGIN"].to_s
          fail!(403, "forbidden", "the Origin is not this server") unless origin.empty? || allowed_origin?(origin)
          return
        end
        @current_session = auth.lookup(r.cookies[Auth::COOKIE])
        fail!(401, "unauthorized", "no valid session; open a new link from the terminal") unless @current_session
        return if SAFE.include?(method)

        guard_mutation(r, path)
      end

      def guard_mutation(r, path)
        group = Web.routes[path.split("/")[1].to_s]
        fail!(405, "read_only", "polispec web is running read-only") if Web.context.read_only && group && group.mutating
        fail!(403, "forbidden", "the CSRF header is missing or wrong") unless Auth.equal?(r.env["HTTP_X_POLISPEC_CSRF"], @current_session.csrf)
        fail!(403, "forbidden", "the Origin is not this server") unless allowed_origin?(r.env["HTTP_ORIGIN"])
        return if COMPUTE.include?(path.split("/")[1].to_s)

        granted, wait = auth.take_mutation(@current_session)
        return if granted

        fail!(429, "rate_limited", "more than #{Auth::MUTATION_LIMIT} changes in a minute", retry_after: wait)
      end

      def serve_static(r)
        fail!(405, "method_not_allowed", "only GET and HEAD are served here") unless SAFE.include?(r.request_method)
        file = static_file(r.path_info)
        fail!(404, "not_found", "no such file") unless file
        stat = File.stat(file)
        etag = %("#{Digest::SHA256.hexdigest("#{stat.size}-#{stat.mtime.to_f}")[0, 24]}")
        response["ETag"] = etag
        response["Cache-Control"] = "no-cache"
        response["Content-Type"] = MIME.fetch(File.extname(file).downcase)
        if r.env["HTTP_IF_NONE_MATCH"].to_s.split(",").map(&:strip).include?(etag)
          response.status = 304
          r.halt
        end
        response.write(File.binread(file))
        r.halt
      end

      def static_file(raw)
        path = Rack::Utils.unescape_path(raw.to_s)
        return nil if path.include?("\0") || path.include?("\\")

        parts = path.split("/").reject(&:empty?)
        return nil if parts.any? { |part| part.start_with?(".") }

        parts = ["index.html"] if parts.empty?
        candidate = File.join(PUBLIC_DIR, *parts)
        candidate = File.join(candidate, "index.html") if File.directory?(candidate)
        return nil unless File.file?(candidate) && MIME.key?(File.extname(candidate).downcase)

        real = File.realpath(candidate)
        root = File.realpath(PUBLIC_DIR)
        real.start_with?("#{root}/") ? real : nil
      rescue ArgumentError, SystemCallError
        nil
      end
    end

    Web.route("session") do |r|
      r.is do
        r.post do
          body = r.POST
          code = body.is_a?(Hash) ? body["code"] : nil
          session = auth.exchange(code)
          fail!(401, "unauthorized", "the link is used or expired; open a new link from the terminal") unless session
          set_session_cookie(session.token)
          session_payload(session)
        end
        r.get { session_payload(current_session) }
        r.delete do
          auth.close(current_session.token)
          clear_session_cookie
          { "ok" => true }
        end
        fail!(405, "method_not_allowed", "unsupported method")
      end
    end

    Web.route("config") do |r|
      r.is do
        r.get { config_payload }
        fail!(405, "method_not_allowed", "unsupported method")
      end
    end

    Dir.glob(File.join(__dir__, "routes", "*.rb")).sort.each { |file| require file }
    Web.routes.each_value { |route| App.hash_branch(:api, route.prefix, &route.block) }
  end
end
