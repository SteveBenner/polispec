# AGENTS.md: polispec

polispec is a plugin built on rplugin, the SDK for agent-harness plugins.
`CLAUDE.md` links to this file, so every harness reads the same text.

## Using it for someone

- It is installed with `~/.rplugin/bin/rplugin install polispec` and checked with
  `~/.rplugin/bin/rplugin doctor polispec`, which must report zero findings. Read
  rplugin's own `~/.rplugin/AGENTS.md` for installing, configuring and
  troubleshooting any plugin.
- What polispec does and its settings (`polispec.enforce`, `polispec.ledger`,
  `polispec.operator` and `polispec.code.specs_repo`, changed with `rplugin settings`) are described in `README.md`; the contract is
  `specs/app.yml`.
- Its skill is `skills/polispec/SKILL.md`; its command, when installed, is `polispec`
  on the user's `PATH`.
- If it owns a corpus, rplugin created it for the plugin. Read and write it
  only through the plugin or `rcorpus`, never by editing its files.

## Changing it

- The manifest is `polispec.rplugin.yml` (schema `rplugin/v1`,
  `~/.rplugin/specs/plugin.yml`). `VERSION`, the manifest's `version` and
  `.codex-plugin/plugin.json` must agree.
- Code uses every capability (secrets, events, state, registry, schedule,
  corpus) through `Rplugin::Ports.for("polispec", root: <plugin root>)`. Never
  call a host's service or read its files directly, and never copy rplugin's
  runtime or catalogue into this plugin.
- Before calling a change done, run `rplugin check polispec`, `rplugin install
  polispec` and `rplugin doctor polispec`, all at zero findings, and run the plugin
  for real.
- Guide: `~/.rplugin/docs/guides/writing-a-plugin.md`.
- Commands are files: `lib/polispec/commands/*.rb` and `lib/polispec/classify/commands/*.rb`
  are glob-loaded, so a new command or classifier family adds a file and edits no registry.
