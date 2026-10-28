#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "tmpdir"
require "socket"
require_relative "smoke"

module Polispec
  module Proof
    NAMESPACE = "polispec-proof"
    SCHEMA = "polispec.proof/v1"
    MANIFEST_PATH = "specs/features.yml"
    PROOFS_DIR = "proofs"

    autoload :Manifest, File.join(LIB, "proof", "manifest")
    autoload :Digest, File.join(LIB, "proof", "digest")
    autoload :Records, File.join(LIB, "proof", "records")
    autoload :Signer, File.join(LIB, "proof", "signer")
    autoload :Runner, File.join(LIB, "proof", "runner")
    autoload :Gate, File.join(LIB, "proof", "gate")
    autoload :Weakening, File.join(LIB, "proof", "weakening")
  end
end
