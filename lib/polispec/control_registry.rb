#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module ControlRegistry
    ENTRY_SCHEMA = "polispec.control/v1"

    module_function

    def schema_id
      ENTRY_SCHEMA
    end

    def action_classes
      ACTION_CLASSES.dup
    end

    def declared?(action_class)
      ACTION_CLASSES.include?(action_class.to_s)
    end
  end
end
