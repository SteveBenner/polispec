#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "support"

module Polispec
  module Classify
    module Generic
      extend Support::Family

      NAMES = %w{
        ls ll dir pwd echo printf true false test [ [[ read cd id whoami hostname uname date sleep which type whereis
        ps top htop pgrep env printenv df du free uptime lsof ss netstat ip ifconfig ping dig nslookup host tree basename
        dirname realpath readlink seq yes tr column fold fmt rev nproc lscpu lsblk man help history alias unalias set
        unset shift return exit wait jobs bg fg trap umask ulimit getopts let hash popd dirs cal bc expr factor
        tput clear reset stty locale md5sum sha1sum sha256sum sha512sum cksum tty groups logname who w last
        xdg-open notify-send
      }.freeze

      class << self
        def classify(cmd)
          return nil if cmd.argv.empty? || claimed?(cmd.name)

          Support.act("fs.write", cmd.text, "path" => cmd.cwd, "unknown" => true, "command" => cmd.name)
        end

        def claimed?(name)
          @claimed ||= Registry.families.values.flat_map { |family| family.respond_to?(:handles) ? family.handles : [] }.uniq
          @claimed.include?(name)
        end
      end
    end

    Registry.register("generic", Generic)
  end
end
