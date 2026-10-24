#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Lint
    module Shipped
      ROWS = [
        ["schemas/*.yml", "schema_doc"],
        ["modules/*.yml", "module"],
        ["packages/*/package.yml", "package"],
        ["packages/*/behavior.yml", "auto"],
        ["packages/**/*.yml", "template"],
        ["config/ledger.starter.yml", "ledger"],
        ["config/harness-features.yml", "hygiene"],
        ["config.yml", "hygiene"],
        ["data/*.yml", "hygiene"],
        ["smoke/host-probes.yml", "hygiene"],
        ["examples/**/*.yml", "auto"],
        ["smoke.yml", "smoke"],
        ["smoke/scenarios/*.yml", "smoke-scenario"],
        ["smoke/live/*.yml", "smoke-scenario"],
        ["specs/polispec/**/*.yml", "auto"],
        ["specs/editions.yml", "editions"],
        ["specs/*.yml", "hygiene"],
        ["hooks/*.yml", "hygiene"],
        ["hooks/*.json", "hygiene"],
        ["polispec.rplugin.yml", "hygiene"],
        ["vendor/**/*.yml", "hygiene"],
        ["web/public/**/*.yml", "hygiene"],
        ["plugin.json", "hygiene"],
        [".claude-plugin/*.json", "hygiene"],
        [".codex-plugin/*.json", "hygiene"],
        [".agents/**/*.json", "hygiene"]
      ].freeze

      module_function

      def pattern(glob)
        source = +""
        index = 0
        while index < glob.length
          if glob[index, 3] == "**/"
            source << "(?:.*/)?"
            index += 3
          elsif glob[index, 2] == "**"
            source << ".*"
            index += 2
          elsif glob[index] == "*"
            source << "[^/]*"
            index += 1
          elsif glob[index] == "?"
            source << "[^/]"
            index += 1
          else
            source << Regexp.escape(glob[index])
            index += 1
          end
        end
        Regexp.new("\\A#{source}\\z")
      end

      TABLE = ROWS.map { |glob, kind| { glob: glob, kind: kind, regexp: pattern(glob) }.freeze }.freeze

      def claim(relative)
        TABLE.find { |row| row[:regexp].match?(relative.to_s) }
      end
    end
  end
end
