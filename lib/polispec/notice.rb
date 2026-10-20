#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "changes"

module Polispec
  module Notice
    LIMIT = 300
    DIR = "notices"
    RELOAD_TEXT = " Hooks changed: run /reload-plugins."

    module_function

    def enabled?
      Engine::Settings.notice?
    rescue StandardError
      false
    end

    def dir
      File.join(State.home, DIR)
    end

    def file_for(session_id)
      name = session_id.to_s.gsub(/[^A-Za-z0-9._-]/, "_")[0, 128]
      return nil if name.empty? || name.start_with?(".")

      File.join(dir, name)
    end

    def line_for(session_id, epoch, now: Time.now)
      return nil unless epoch && enabled?

      file = file_for(session_id)
      return nil unless file

      seen = File.file?(file) ? File.read(file).strip : nil
      if seen.nil?
        remember(file, epoch)
        return nil
      end
      return nil if seen == epoch

      remember(file, epoch)
      change = Changes.records.reverse.find { |entry| entry["epoch_after"] == epoch } || Changes.records.reverse.find { |entry| entry["epoch_before"] == seen }
      change ? render(change, epoch, now) : nil
    rescue StandardError
      nil
    end

    def remember(file, epoch)
      FileUtils.mkdir_p(File.dirname(file), mode: 0o700)
      temp = "#{file}.#{Process.pid}.tmp"
      File.write(temp, "#{epoch}\n", perm: 0o600)
      File.rename(temp, file)
    end

    def render(change, epoch, now)
      reload = Array(change["effects"]).any? { |item| item["class"] == "reload" }
      subject = change["subject"].is_a?(Hash) ? change["subject"].values.map { |value| value.is_a?(Array) ? value.join(",") : value.to_s }.reject(&:empty?).first(2).join("/") : ""
      head = "polispec: #{change['kind']}#{subject.empty? ? '' : " #{subject}"} landed #{ago(change['ts'], now)} (epoch #{epoch.sub('ep_', '')[0, 8]}); it applies from this call."
      tail = reload ? RELOAD_TEXT : ""
      text = head + tail
      return text if text.length <= LIMIT

      room = LIMIT - tail.length
      "#{head[0, [room - 3, 0].max]}...#{tail}"[0, LIMIT]
    end

    def ago(stamp, now)
      seconds = (now - Time.iso8601(stamp.to_s)).to_i
      return "just now" if seconds < 5
      return "#{seconds}s ago" if seconds < 60
      return "#{seconds / 60}m ago" if seconds < 3600
      return "#{seconds / 3600}h ago" if seconds < 86_400

      "#{seconds / 86_400}d ago"
    rescue ArgumentError
      "earlier"
    end
  end
end
