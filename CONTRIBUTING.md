# Contributing to Cuate

Thanks for your interest in Cuate! Contributions of all sizes are welcome —
from a typo fix or a translation tweak to a whole new addon. If you're not sure
where to start, look for issues labeled
[`good first issue`](https://github.com/kidem42/Cuate/labels/good%20first%20issue),
or just open an issue with your idea and we'll figure out the approach together.

## How to contribute

1. **Small fixes** (typos, obvious bugs) — just open a pull request.
2. **Non-trivial changes** — please open an issue first to discuss the
   approach; it saves you from building something that can't be merged.
3. Fork, create a branch, make your change. Match the style and conventions of
   the surrounding code.
4. Make sure it builds: open `Cuate.xcodeproj` in Xcode 26+, or run
   `./scripts/make-dmg.sh`. For the Android app, see
   [`android/README.md`](android/README.md).
5. Open a pull request describing what changed and why.

## License & CLA

Cuate is licensed under the **GNU AGPL-3.0** (see [LICENSE](LICENSE)) and uses
the standard dual-licensing model: the code is free for the community under the
AGPL, while the author also distributes official builds and commercial licenses.
To make that possible, contributions are accepted under a
[Contributor License Agreement](CLA.md). In short, the CLA:

- keeps your contribution available to everyone under **AGPL-3.0**
  (inbound = outbound), and
- also lets the maintainer include it in **commercially licensed** versions of
  Cuate.

You keep the copyright to your work — you grant a license, you don't give it
away.

**Signing is automatic:** when you open your first pull request, the CLA bot
will leave a comment asking you to reply with a short signing phrase. That's
it — one comment, once per contributor, and the bot remembers you for all
future PRs.

## Commercial use

The AGPL-3.0 requires that any **distributed or network-deployed** derivative is
also released under the AGPL-3.0, with full corresponding source. If you want to
use Cuate in a **closed-source or commercial** product without those
obligations, a commercial license is available from the author:
**[kravec42@gmail.com](mailto:kravec42@gmail.com)**.
