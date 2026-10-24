#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "openssl"
require_relative "../delegate"
require_relative "../editions"
require_relative "../schema/core"
require_relative "../lint"

module Polispec
  module Delegate
    module Grants
      Loaded = Struct.new(:grants, :problems)
      TAG = /\Av\d+\.\d+\.\d+([.-][0-9A-Za-z.-]+)?\z/.freeze
      MAX_ARGV = 12
      MAX_ELEMENT = 200
      EXCEPTIONS_VERBS = %w[exceptions-add exceptions-promote exceptions-remove].freeze
      VERBS = (Delegate::VERBS + EXCEPTIONS_VERBS).freeze
      EXCEPTIONS_VALUE_FLAGS = { "add" => %w[--command --tool --kind --rule --note], "promote" => %w[--command --note], "remove" => [] }.freeze
      EXCEPTIONS_SWITCHES = { "add" => %w[--global], "promote" => %w[--global], "remove" => [] }.freeze
      PROPOSAL_ID = /\Aapr_[0-9a-f]{12}\z/.freeze
      ENTRY_ID = /\Aaex_[0-9a-f]{12}\z/.freeze

      module_function

      def load
        path = Delegate.grants_path
        return Loaded.new([], []) unless File.exist?(path)
        return Loaded.new([], ["grants file is not a regular file"]) unless File.file?(path)
        return Loaded.new([], ["grants file is larger than #{MAX_BYTES} bytes"]) if File.size(path) > MAX_BYTES

        stat = File.stat(path)
        return Loaded.new([], ["grants file is not owned by this user"]) unless stat.uid == Process.uid
        return Loaded.new([], ["grants file is writable by group or others"]) unless (stat.mode & 0o022).zero?

        document = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
        problems = validate(document)
        problems.empty? ? Loaded.new(document["grants"], []) : Loaded.new([], problems)
      rescue Psych::Exception, SystemCallError, IOError => e
        Loaded.new([], ["grants file cannot be read: #{e.message}"])
      end

      def validate(document)
        return ["grants file is not a mapping"] unless document.is_a?(Hash)

        problems = Schema.validate("delegate_grants", Schema::Document.normalize(document)).map { |error| "#{error.pointer.empty? ? '/' : error.pointer} #{error.message}" }
        return problems unless problems.empty?

        grants = document["grants"]
        problems << "/grants has more than #{MAX_GRANTS} entries" if grants.length > MAX_GRANTS
        apps = grants.map { |grant| grant["app"] }
        apps.select { |app| apps.count(app) > 1 }.uniq.each { |app| problems << "/grants duplicates app #{app}" }
        problems
      end

      def find(app)
        load.grants.find { |grant| grant["app"] == app.to_s }
      end

      def digest(token)
        Digest::SHA256.hexdigest(token.to_s)
      end

      def authenticate(app, token)
        return nil unless app.is_a?(String) && token.is_a?(String) && !token.empty?

        grant = find(app)
        return nil unless grant
        return nil unless secure_equal?(digest(token), grant["token_sha256"].to_s)

        grant
      end

      def secure_equal?(left, right)
        return false unless left.bytesize == right.bytesize

        if OpenSSL.respond_to?(:fixed_length_secure_compare)
          OpenSSL.fixed_length_secure_compare(left, right)
        else
          left.bytes.zip(right.bytes).reduce(0) { |acc, (a, b)| acc | (a ^ b) }.zero?
        end
      end

      def normalize_target(value)
        value.to_s == "prod" ? "stable" : value.to_s
      end

      def covers?(grant, argv)
        return "argv must be a list of strings" unless argv.is_a?(Array) && argv.all? { |item| item.is_a?(String) }
        return "argv is empty" if argv.empty?
        return "argv has more than #{MAX_ARGV} elements" if argv.length > MAX_ARGV
        return "argv element longer than #{MAX_ELEMENT} bytes" if argv.any? { |item| item.bytesize > MAX_ELEMENT }
        return "argv element contains NUL" if argv.any? { |item| item.include?("\0") }

        verb = argv.first
        return exceptions_reason(grant, argv.drop(1)) if verb == "exceptions"
        return "verb not granted" unless VERBS.include?(verb) && Array(grant["verbs"]).include?(verb)

        verb == "promote" ? promote_reason(grant, argv.drop(1)) : deploy_reason(grant, argv.drop(1))
      end

      def flag_name(item)
        item.to_s.match?(/\A--verbose=(?:text|json)\z/) ? "--verbose" : item
      end

      def exceptions_locked?
        !Editions.allowed?("exceptions.delegate_promote")
      end

      def exceptions_argv?(argv)
        argv.is_a?(Array) && argv.first == "exceptions"
      end

      def exceptions_reason(grant, rest)
        sub = rest.first
        return "verb not granted" unless EXCEPTIONS_VALUE_FLAGS.key?(sub) && Array(grant["verbs"]).include?("exceptions-#{sub}")
        return "verb not available in this edition" if exceptions_locked?

        values = []
        switches = []
        positional = []
        queue = rest.drop(1)
        until queue.empty?
          item = queue.shift
          name, inline = item.start_with?("--") ? item.split("=", 2) : [item, nil]
          if EXCEPTIONS_SWITCHES.fetch(sub).include?(name)
            return "flag not granted: #{item}" unless inline.nil?
            return "flag given twice: #{name}" if switches.include?(name)

            switches << name
          elsif EXCEPTIONS_VALUE_FLAGS.fetch(sub).include?(name)
            value = inline || queue.shift
            return "flag needs a value: #{name}" if value.nil?
            return "flag given twice: #{name}" if values.include?(name)

            values << name
          elsif flag_name(item) == "--verbose"
            return "flag not granted: #{item}" unless Array(grant["flags"]).include?("--verbose")
          elsif item.start_with?("--")
            return "flag not granted: #{item}"
          else
            positional << item
          end
        end
        exceptions_arguments_reason(sub, positional, values)
      end

      def exceptions_arguments_reason(sub, positional, values)
        case sub
        when "add"
          positional.empty? ? nil : "unexpected argument: #{positional.first}"
        when "promote"
          return "promote takes proposal ids" if positional.empty?
          return "promote takes proposal ids: #{positional.find { |id| !PROPOSAL_ID.match?(id) }}" unless positional.all? { |id| PROPOSAL_ID.match?(id) }
          return "proposal id given twice" unless positional.uniq.length == positional.length
          return "--command takes a single proposal id" if values.include?("--command") && positional.length != 1

          nil
        else
          positional.length == 1 && ENTRY_ID.match?(positional.first) ? nil : "remove takes one exception id"
        end
      end

      def promote_reason(grant, rest)
        flags = Array(grant["flags"])
        project = nil
        target = nil
        index = 0
        while index < rest.length
          item = rest[index]
          if item == "--to" || item.start_with?("--to=")
            return "flag not granted: --to given twice" if target

            if item == "--to"
              index += 1
              target = rest[index]
            else
              target = item.sub("--to=", "")
            end
            return "target not granted: missing" if target.nil? || target.empty?
          elsif item.start_with?("--")
            return "flag not granted: #{item}" unless FLAGS_ALLOWED.include?(flag_name(item)) && flags.include?(flag_name(item)) && item != "--tag"
          elsif project
            return "unexpected argument: #{item}"
          else
            project = item
          end
          index += 1
        end
        return "project not granted: missing" unless project
        return "project not granted: #{project}" unless Array(grant["projects"]).include?(project)
        return "target not granted: missing" unless target
        return "target not granted: #{target}" unless Array(grant["targets"]).include?(normalize_target(target))

        nil
      end

      def deploy_reason(grant, rest)
        flags = Array(grant["flags"])
        positional = []
        index = 0
        while index < rest.length
          item = rest[index]
          if item == "--tag"
            return "flag not granted: --tag" unless flags.include?("--tag")

            index += 1
            return "tag is not a release tag: #{rest[index]}" unless rest[index].to_s.match?(TAG)
          elsif item.start_with?("--")
            return "flag not granted: #{item}" unless FLAGS_ALLOWED.include?(flag_name(item)) && flags.include?(flag_name(item))
          else
            positional << item
          end
          index += 1
        end
        return "deploy takes a project and a target" unless positional.length == 2

        project, env = positional
        return "project not granted: #{project}" unless Array(grant["projects"]).include?(project)
        return "target not granted: #{env}" unless Array(grant["targets"]).include?(normalize_target(env))

        nil
      end

      def public_scope(grant)
        grant.reject { |key, _| key == "token_sha256" }
      end

      def write(grants)
        FileUtils.mkdir_p(Delegate.dir, mode: 0o700)
        FileUtils.chmod(0o700, Delegate.dir)
        Lint.guard_write!(YAML.dump("schema" => SCHEMA, "grants" => grants), path: Delegate.grants_path, kind: "delegate_grants")
        temp = File.join(Delegate.dir, ".grants.#{Process.pid}.#{SecureRandom.hex(4)}.tmp")
        File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(YAML.dump("schema" => SCHEMA, "grants" => grants)) }
        File.rename(temp, Delegate.grants_path)
        File.chmod(0o600, Delegate.grants_path)
      ensure
        File.delete(temp) if temp && File.exist?(temp)
      end

      def new_token
        "#{TOKEN_PREFIX}#{SecureRandom.hex(32)}"
      end
    end
  end
end
