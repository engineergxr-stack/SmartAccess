# Contributing to SmartAccess

Thanks for considering a contribution.

## License & Copyright assignment

By submitting a pull request to this repository, you agree that:

1. Your contribution is licensed under **AGPL-3.0**, the same license as the rest of the project.
2. You grant **the project maintainer** a **perpetual, worldwide, royalty-free license** to **also** sub-license your contribution under a **separate commercial license** (the dual-licensing model — see [`LICENSE-COMMERCIAL.md`](./LICENSE-COMMERCIAL.md)).
3. You confirm that your contribution is **your own work** and does not infringe any third party's intellectual property.

This is a standard dual-licensing CLA model used by Sentry, GitLab, MongoDB, and many other projects. It is required so that commercial customers can rely on the project without licensing uncertainty.

## What we welcome

- Bug fixes with a clear reproduction
- Documentation improvements
- Test coverage additions
- New `DNSResolver` implementations (Static / Custom HTTPDNS protocols)
- Platform extensions (Android port, Linux probe runners, etc.)

## What we will likely NOT merge

- Features that break the project's **stated boundaries**:
  - Generic proxy / VPN functionality
  - SNI rewriting / protocol obfuscation
  - Anything that helps bypass network regulation
- Features that introduce non-AGPL-compatible dependencies
- Cosmetic-only changes without functional value

## Process

1. Open an issue first to discuss the change (large changes only)
2. Fork → branch from `main` → make the change
3. Add or update unit tests
4. Open a PR. Title format: `[scope] Brief description` (e.g. `[DNS] Add custom HTTPDNS json format support`)
5. Sign off your commits via `git commit -s` (Developer Certificate of Origin)

## Questions

For licensing or contribution questions: engineer.gxr@gmail.com
