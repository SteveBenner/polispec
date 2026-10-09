#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  Action = Struct.new(:class, :env_hint, :raw, keyword_init: true) do
    def initialize(**attrs)
      super
      self[:env_hint] = {} if self[:env_hint].nil?
    end

    def action_class
      self[:class]
    end

    def to_h
      { "class" => self[:class], "env_hint" => self[:env_hint], "raw" => self[:raw] }
    end
  end

  Verdict = Struct.new(:level, :rule_id, :reason, :next_step, :allow_once_id, keyword_init: true) do
    def severity
      LEVELS.index(level.to_s) || 0
    end

    def allow?
      level.to_s == "allow"
    end

    def warn?
      level.to_s == "warn"
    end

    def deny?
      level.to_s == "deny"
    end

    def to_h
      { "level" => level, "rule_id" => rule_id, "reason" => reason, "next_step" => next_step, "allow_once_id" => allow_once_id }
    end
  end

  def Verdict.worst(verdicts)
    verdicts.max_by(&:severity) || new(level: "allow")
  end

  Target = Struct.new(:project, :env, :policy, :roster, :policy_source, :digest, keyword_init: true) do
    def to_h
      { "project" => project, "env" => env, "policy_source" => policy_source, "digest" => digest }
    end
  end
end
