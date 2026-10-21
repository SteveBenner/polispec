#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "ipaddr"
require "json"
require_relative "../web"
require_relative "../operator/tty"

module Polispec
  class WebCommand
    USAGE = "usage: polispec web [--bind ADDR] [--port N] [--expose] [--open] [--read-only] [--json] | url [--json] | token set | unit [--json]"
    UNIT_PATH = "~/.config/systemd/user/polispec-web.service"
    EXPOSE_PHRASE = "expose polispec web"
    TOKEN_MAX = 512
    OPENERS = %w[xdg-open open].freeze

    class Failure < StandardError
      attr_reader :code, :status

      def initialize(code, message, status = 1)
        super(message)
        @code = code
        @status = status
      end
    end

    def self.run(args)
      new.run(args)
    end

    def run(args)
      args = args.dup
      return help if args.include?("--help") || args.include?("-h")

      @json = args.include?("--json")
      Web.ensure_edition!
      case args.first
      when "url" then url(args.drop(1))
      when "token" then token(args.drop(1))
      when "unit" then unit(args.drop(1))
      else serve(args)
      end
    rescue Failure => e
      fail_with(e.code, e.message, e.status)
    rescue Web::Excluded => e
      fail_with(e.code, e.message, 2)
    rescue Web::Server::Refused => e
      fail_with(e.code, e.message, 1)
    rescue Operator::Tty::NotTty => e
      fail_with("not_tty", e.message, 3)
    rescue Operator::Tty::PhraseMismatch => e
      fail_with("confirmation_failed", e.message, 1)
    rescue Polispec::Error => e
      fail_with("web_failed", e.message, 1)
    end

    private

    def help
      puts USAGE
      0
    end

    def usage
      warn USAGE
      2
    end

    def fail_with(code, message, status)
      if @json
        puts JSON.generate("error" => code, "message" => message)
      else
        warn "polispec: #{code}: #{message}"
      end
      status
    end

    def serve(args)
      options = parse(args)
      return usage unless options

      bind = options[:bind] || Engine::Settings.web_bind
      port = options[:port] || Engine::Settings.web_port
      exposed = confirm_expose(bind, options[:expose])
      Web.load!
      server = Web::Server.new(bind: bind, port: port, read_only: options[:read_only], exposed: exposed)
      server.run { |info| announce(info, options) }
      0
    end

    def parse(args)
      options = { expose: false, open: false, read_only: false }
      rest = args.reject { |arg| arg == "--json" }
      until rest.empty?
        arg = rest.shift
        case arg
        when "--expose" then options[:expose] = true
        when "--open" then options[:open] = true
        when "--read-only" then options[:read_only] = true
        when "--bind" then options[:bind] = rest.shift
        when "--port" then options[:port] = integer_port(rest.shift)
        when /\A--bind=(.+)\z/ then options[:bind] = Regexp.last_match(1)
        when /\A--port=(.+)\z/ then options[:port] = integer_port(Regexp.last_match(1))
        else return nil
        end
      end
      return nil if options.key?(:bind) && options[:bind].to_s.empty?
      return nil if options.key?(:port) && options[:port].nil?

      options
    end

    def integer_port(text)
      return nil unless text.to_s.match?(/\A\d{1,5}\z/)

      value = text.to_i
      value <= 65_535 ? value : nil
    end

    def loopback?(bind)
      return true if bind.to_s.downcase == "localhost"

      IPAddr.new(bind.to_s).loopback?
    rescue IPAddr::Error
      false
    end

    def confirm_expose(bind, expose)
      return false if loopback?(bind)
      raise Failure.new("expose_required", "#{bind} is not a loopback address; pass --expose and confirm on a terminal to listen on it", 2) unless expose

      Operator::Tty.confirm!(EXPOSE_PHRASE, prompt: "polispec web will listen on #{bind}, reachable by other machines. Anyone holding a link can change policy.")
      true
    end

    def announce(info, options)
      link = info.url
      if @json
        puts JSON.generate("url" => link, "bind" => info.bind, "port" => info.port, "pid" => info.pid, "read_only" => options[:read_only])
      else
        puts "polispec web: serving #{info.url_host}:#{info.port}#{' (read-only)' if options[:read_only]}; stop with Ctrl-C"
        puts "open this link within #{Web::Auth::CODE_TTL} seconds, it works once:"
        puts link
      end
      $stdout.flush
      launch(link) if options[:open]
    end

    def launch(link)
      opener = OPENERS.find { |name| ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) } }
      return warn("polispec: no xdg-open or open found; open the link by hand") unless opener

      Process.detach(Process.spawn(opener, link, in: File::NULL, out: File::NULL, err: File::NULL))
    rescue SystemCallError => e
      warn "polispec: could not run #{opener}: #{e.message}"
    end

    def url(args)
      return usage unless (args - ["--json"]).empty?

      info = Web::Server.running
      raise Failure.new("not_running", "polispec web is not running; start it with polispec web") unless info

      secret_file = Web::Auth.secret_path
      raise Failure.new("no_secret", "the launch secret is missing; restart polispec web") unless File.file?(secret_file)

      code = Web::Auth.mint(File.read(secret_file).strip)
      host = info["bind"].to_s.include?(":") ? "[#{info['bind']}]" : info["bind"]
      host = "127.0.0.1" if ["0.0.0.0", "[::]"].include?(host)
      origin = Web.public_origin(info["public_origin"])
      link = "#{origin || "http://#{host}:#{info['port']}"}/#k=#{code}"
      @json ? puts(JSON.generate("url" => link, "bind" => info["bind"], "port" => info["port"], "pid" => info["pid"])) : puts(link)
      0
    end

    def token(args)
      return usage unless args == ["set"]

      console = Operator::Tty.console
      raise Operator::Tty::NotTty, "this action needs an interactive terminal; an agent shell cannot run it" unless console && $stdin.tty?

      value = console.getpass("Paste the delegate token for polispec-web: ").to_s.strip
      raise Failure.new("invalid_token", "the token is empty or longer than #{TOKEN_MAX} characters", 2) if value.empty? || value.length > TOKEN_MAX

      Web.ensure_dir
      path = File.join(Web.dir, "delegate.token")
      temp = "#{path}.#{Process.pid}.tmp"
      File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write("#{value}\n") }
      File.rename(temp, path)
      puts "polispec web: delegate token saved to #{path}"
      0
    end

    def unit(args)
      return usage unless (args - ["--json"]).empty?

      binary = File.join(Polispec::ROOT, "bin", "polispec")
      text = <<~UNIT
        [Unit]
        Description=polispec web

        [Service]
        ExecStart=#{binary} web
        Restart=on-failure
        KillMode=mixed
        TimeoutStopSec=30

        [Install]
        WantedBy=default.target
      UNIT
      commands = ["write the unit to #{UNIT_PATH}", "systemctl --user daemon-reload && systemctl --user enable --now polispec-web"]
      if @json
        puts JSON.generate("unit" => text, "path" => UNIT_PATH, "commands" => commands)
      else
        puts text
        commands.each { |line| puts line }
      end
      0
    end
  end

  CLI.register("web", WebCommand, summary: "serve the local web app: polispec web [--bind ADDR] [--port N] [--expose] [--open] [--read-only], url, token set, unit")
end
