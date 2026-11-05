#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "support"

module Polispec
  module Classify
    module HttpRemote
      extend Support::Family

      NAMES = [].freeze
      PROGRAMS = %w[curl wget http https].freeze
      FORGE_HOSTS = %w[github.com api.github.com gitlab.com bitbucket.org api.bitbucket.org].freeze
      METHODS = %w[GET HEAD OPTIONS POST PUT PATCH DELETE].freeze
      CURL_BODY = %w[-d --data --data-binary --data-raw --data-ascii --data-urlencode -F --form --form-string -T --upload-file --json].freeze
      WGET_BODY = %w[--post-data --post-file --body-data --body-file].freeze
      TARGET = %r{\A(?:[a-z][a-z0-9+.-]*://)?(?:[^/@\s]*@)?([A-Za-z0-9.-]+)(?::\d+)?(/\S*)?\z}.freeze

      class << self
        def classify(cmd)
          return [] unless PROGRAMS.include?(cmd.name)

          host, path = forge_target(cmd)
          return [] unless host

          method = http_method(cmd)
          return [] unless method

          out = [Action.new(class: "shell.exec", env_hint: { "path" => cmd.cwd }, raw: { "remote_change" => "#{cmd.name} #{method} #{host}" })]
          ref = path.to_s[%r{/git/refs/(.+?)(?:[?#].*)?\z}, 1]
          out << ref_push(cmd, ref, method) if ref
          out
        end

        def ref_push(cmd, raw, method)
          tag = raw.match?(%r{\A(?:refs/)?tags/})
          name = raw.sub(%r{\A(?:refs/)?(?:heads|tags)/}, "")
          hint = { "path" => cmd.cwd }
          hint[tag ? "tag" : "ref"] = name
          hint["delete"] = true if tag && method == "DELETE"
          Support.act("git.push", cmd.text, hint)
        end

        def forge_target(cmd)
          cmd.args.map(&:to_s).each do |arg|
            next if arg.start_with?("-") || METHODS.include?(arg.upcase) || arg.include?("=") && !arg.include?("/")

            match = TARGET.match(arg)
            return [match[1].downcase, match[2]] if match && FORGE_HOSTS.include?(match[1].downcase)
          end
          nil
        end

        def http_method(cmd)
          args = cmd.args.map(&:to_s)
          explicit = explicit_method(cmd, args)
          return explicit unless explicit.nil? || explicit == "GET"
          return "POST" if body?(cmd, args)

          nil
        end

        def explicit_method(cmd, args)
          case cmd.name
          when "curl" then Support.option_value_cluster(args, %w[X], %w[--request]).to_s.upcase.then { |value| value.empty? ? nil : value }
          when "wget" then args.filter_map { |arg| arg.split("=", 2).last.upcase if arg.start_with?("--method=") }.first
          else args.find { |arg| METHODS.include?(arg.upcase) && arg == arg.upcase }&.upcase
          end
        end

        def body?(cmd, args)
          case cmd.name
          when "curl" then args.any? { |arg| CURL_BODY.include?(arg) || CURL_BODY.any? { |flag| flag.start_with?("--") && arg.start_with?("#{flag}=") } || short_body?(arg) }
          when "wget" then args.any? { |arg| WGET_BODY.any? { |flag| arg == flag || arg.start_with?("#{flag}=") } }
          else args.any? { |arg| arg.match?(/\A[A-Za-z0-9_.-]+(?::?=|:=@|=@)/) && !arg.include?("/") && !arg.start_with?("-") } || args.include?("--form") || args.include?("-f")
          end
        end

        def short_body?(arg)
          arg.match?(/\A-[dFT]./) && !arg.start_with?("--")
        end
      end
    end

    Registry.register("http_remote", HttpRemote)
  end
end
