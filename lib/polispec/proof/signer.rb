#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../harness_controls/plane"

module Polispec
  module Proof
    module Signer
      KEY_NAME = "producer_ed25519"

      module_function

      def key_path
        override = ENV["POLISPEC_PROOF_KEY"].to_s.strip
        return File.expand_path(override) if !override.empty? && unsealed?

        File.join(State.home, "proof", KEY_NAME)
      end

      def unsealed?
        HarnessControls::Plane.resolve["status"] == "unsealed"
      rescue StandardError
        false
      end

      def short_host
        Socket.gethostname.to_s.split(".").first.to_s
      end

      def producer_id(key = key_path)
        comment = File.read("#{key}.pub").strip.split(" ", 3)[2].to_s
        host = comment.split("@", 2)[1]
        host && !host.empty? ? "host-#{host}" : comment
      rescue SystemCallError
        raise Polispec::Error, "key_missing: no public key at #{key}.pub"
      end

      def public_line(key = key_path)
        File.read("#{key}.pub").strip
      rescue SystemCallError
        raise Polispec::Error, "key_missing: no public key at #{key}.pub"
      end

      def trust_entry(key = key_path)
        { "id" => producer_id(key), "key" => public_line(key), "kind" => "host" }
      end

      def generate(key = key_path)
        raise Polispec::Error, "key_exists: #{key} already exists" if File.exist?(key) || File.exist?("#{key}.pub")

        FileUtils.mkdir_p(File.dirname(key), mode: 0o700)
        _out, err, status = Trace.capture3("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "polispec-proof@#{short_host}", "-f", key, trace: :silent)
        raise Polispec::Error, "keygen_failed: #{err.to_s.strip}" unless status.success?

        trust_entry(key)
      end

      def sign(body, key = key_path)
        raise Polispec::Error, "key_missing: no producer key at #{key}" unless File.file?(key)

        Dir.mktmpdir("polispec-proof") do |dir|
          file = File.join(dir, "body")
          File.write(file, body)
          _out, err, status = Trace.capture3("ssh-keygen", "-Y", "sign", "-f", key, "-n", NAMESPACE, file, trace: :silent)
          raise Polispec::Error, "sign_failed: #{err.to_s.strip}" unless status.success?

          File.read("#{file}.sig")
        end
      end

      def sign_record(record, key = key_path)
        identified = Records.identify(record.reject { |name, _| name == "producer" }.merge("producer" => producer_id(key)))
        identified.merge("signature" => sign(Records.signed_body(identified), key))
      end

      def verify(record, manifest)
        producer = manifest.trusted_producers.find { |entry| entry["id"] == record["producer"] }
        return [false, "producer_unknown"] unless producer

        verified = verify_body(Records.signed_body(record), record["signature"].to_s, producer)
        verified ? [true, nil] : [false, "signature_invalid"]
      end

      def verify_body(body, signature, producer)
        Dir.mktmpdir("polispec-proof") do |dir|
          signers = File.join(dir, "allowed_signers")
          sig = File.join(dir, "body.sig")
          File.write(signers, "#{producer['id']} namespaces=\"#{NAMESPACE}\" #{producer['key']}\n")
          File.write(sig, signature)
          _out, _err, status = Trace.capture3("ssh-keygen", "-Y", "verify", "-f", signers, "-I", producer["id"], "-n", NAMESPACE, "-s", sig, stdin_data: body, trace: :silent)
          status.success?
        end
      end

      def key_parses?(line)
        Dir.mktmpdir("polispec-proof") do |dir|
          file = File.join(dir, "key.pub")
          File.write(file, "#{line.to_s.strip}\n")
          _out, _err, status = Trace.capture3("ssh-keygen", "-l", "-f", file, trace: :silent)
          status.success?
        end
      end
    end
  end
end
