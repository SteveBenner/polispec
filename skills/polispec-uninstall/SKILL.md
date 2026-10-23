---
name: polispec-uninstall
description: >
  Show where polispec is deployed on this host, preview removing all of it,
  and hand the person the command that removes it and the command that puts it
  back. Use when the user asks to uninstall, remove, clean up or reset polispec,
  to see everything polispec has wired into the machine, or to restore a
  previous uninstall.
---

# polispec-uninstall

polispec records every place it is deployed in one manifest. `polispec uninstall --all` backs up each file it will change, removes every deployment through the uninstaller that wrote it, and prints the command that restores it. An agent shell has no terminal, so the real run and the real restore are for the person to type.

## Steps

1. Show what is deployed: `polispec deployments --scan --json`. The scan adds entries for installs that predate the manifest. Summarise by class: wiring (hooks, skill and rule links, git hook shims, harness-control overlays), pins (the current link and the `~/.local/bin` link), rplugin (the store link), data (ledger, settings file, state home).
2. Preview the removal: `polispec uninstall --all --dry-run`. It writes nothing. Show the backup id it would use, every file it would copy, every step in order, and the restore command.
3. Explain the classes. `--keep wiring,pins,rplugin,data` leaves a class alone; the default keeps nothing. Release directories under the data home are never removed, they are the rollback. A marketplace plugin is reported with the harness command that removes it and is not touched. A ledger or settings file that lives inside the global shelf or any git repository is kept and reported, and the global shelf and the rulebooks committed in governed repositories are never touched.
4. Hand the person the exact command to run in their own terminal: `polispec uninstall --all` (add `--keep ...` when they chose one). It asks for the phrase `uninstall polispec`. If the person asks you to run it, say that an agent shell cannot (`not_tty`) and do not try to get around that.
5. After they ran it, show the backup directory and the restore command from its output.

## Restore

- `polispec restore --list` shows the backups.
- `polispec restore <id> --dry-run` shows what it would put back. Without `--mode` it re-runs each installer at the recorded targets (`rewire`); `--mode bytes` copies back the backed-up files and refuses any file edited since (`edited_since`).
- The real restore asks for the phrase `restore polispec` and is also for the person to type. Data (ledger, settings file, state home) comes back only to paths that are absent; otherwise it reports `data_conflict` and leaves them.

## Never

- Do not run `polispec uninstall --all` or `polispec restore <id>` without `--dry-run` from an agent shell.
- Do not delete a backup directory.
