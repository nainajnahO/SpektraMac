# Security policy

## Reporting a vulnerability

Please don't report a security problem in a public issue. Report it privately instead, with **Report a
vulnerability** on the repository's [Security tab](https://github.com/nainajnahO/SpektraMac/security/advisories/new).
Only the maintainer, [@nainajnahO](https://github.com/nainajnahO), sees it.

Say what you found, how to reproduce it (with the file that triggers it, if there is one), and which SpektraMac (a
release, or the commit you built) and macOS you used.

You'll get a reply within a month, and updates on the report until it's fixed. Please keep it private until the fix
is released.

## After a fix

The fix comes out in a new release. The report is then published as a GitHub security advisory, crediting you if
you'd like, and the release notes link to it.

## Supported versions

| Version | Security fixes |
|---|---|
| The latest release | Yes |
| `main` | Yes |
| Older releases | No |

Releases are source only, so there's no older build to patch: updating means building the latest release.

## What counts

SpektraMac runs in Apple's App Sandbox with the hardened runtime, has no network access, and reads only the files you
choose: photos and presets. A vulnerability is something that gets past those limits or misuses them, for example:

- a photo or preset that makes SpektraMac run code, or read or write files you didn't choose, when it's opened;
- the same in `spektra-cli`, which runs outside the sandbox.

A file that only makes SpektraMac show an error or quit is an ordinary bug, so
[open an issue](https://github.com/nainajnahO/SpektraMac/issues/new) for it.

SpektraMac opens photos through Apple's Image I/O and Core Image. If a file also crashes Preview or Quick Look, the bug
is most likely in Apple's decoder: report it to [Apple Security Research](https://security.apple.com) as well.
