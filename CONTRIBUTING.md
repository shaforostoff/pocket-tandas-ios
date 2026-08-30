# Contributing to Pocket Tandas

Thanks for your interest in contributing! Pocket Tandas is **dual-licensed**, so
there are two small legal requirements on every contribution. Both are checked
or stated below — please read before opening a pull request.

## 1. Sign off your commits (DCO)

This project uses the [Developer Certificate of Origin](DCO) (DCO 1.1). Every
commit must carry a `Signed-off-by` trailer certifying you have the right to
submit it. Add it automatically with the `-s` flag:

```sh
git commit -s -m "Your message"
```

This appends a line like:

```
Signed-off-by: Your Name <you@example.com>
```

(The name/email must match your git `user.name` / `user.email`.)

A CI check (`.github/workflows/dco.yml`) **fails any pull request whose commits
are missing the sign-off.** To fix an existing branch, re-sign its commits:

```sh
git rebase --signoff <base-branch>
git push --force-with-lease
```

## 2. License grant for dual-licensing

The DCO certifies *origin*, but it does not by itself grant the rights needed to
distribute your contribution under the project's **commercial** license (used
for the App Store build — see [LICENSING.md](LICENSING.md)). For that,
contributions are also accepted under the
[Contributor License Agreement](CLA.md): you keep ownership of your work but
grant the maintainer the right to license it under **both** the GPL and the
commercial license.

**By submitting a contribution you agree to both the DCO and the CLA.** If a
contribution is not your own original work, don't submit it unless you have the
right to and you attribute the source and its license.

## How to contribute

1. **Open an issue first** for anything non-trivial, so the approach can be
   discussed before you invest time.
2. **Fork and branch** from `main`; keep each PR focused on one change.
3. **Build and test** before submitting:
   ```sh
   xcodebuild -project "Pocket Tandas.xcodeproj" -scheme "Pocket Tandas" \
     -destination 'platform=iOS Simulator,name=iPhone 15' build
   # and run the unit tests (Cmd-U in Xcode, or `xcodebuild test`)
   ```
4. **Open a pull request** (commits signed off) describing what changed and why.

## Code conventions

- Match the surrounding style; keep the existing file-banner comments.
- **Every new `.swift` file must start with the SPDX license header** used
  throughout the project:
  ```swift
  // Pocket Tandas
  // Copyright (C) 2026 Mykola Shaforostov
  // SPDX-License-Identifier: GPL-3.0-or-later
  // Dual-licensed: GPLv3 (see LICENSE) or a commercial license. See LICENSING.md.
  ```
- Keep model/service classes plain `@Observable` (not `@MainActor`); marshal
  audio callbacks to the main thread explicitly.
- Add or update unit tests for logic changes where practical.

Thank you!
