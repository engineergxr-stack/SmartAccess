# SmartAccess

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Commercial License](https://img.shields.io/badge/Commercial-Available-green.svg)](./LICENSE-COMMERCIAL.md)
[![Platform](https://img.shields.io/badge/Platform-iOS%2015%2B-lightgrey.svg)]()
[![Swift](https://img.shields.io/badge/Swift-5.7%2B-orange.svg)]()
[![Tests](https://img.shields.io/badge/Tests-passing-success.svg)]()

> **A client-side connectivity path selection SDK for iOS.**
> Concurrently probes multiple connection paths (direct domains, backup
> domains, customer-operated relays, HTTPDNS fallback) and routes traffic
> to whichever is healthy *right now*. When one path dies, switchover
> happens in seconds.

SmartAccess is **not** a VPN, **not** a generic proxy, **not** a hosted
gateway, **not** an arbitrary URL/IP forwarder. It only serves
customer-owned or customer-authorized endpoints, and every endpoint
must come from a **customer-signed policy**.

---

## Table of Contents

- [Why SmartAccess](#why-smartaccess)
- [What it solves](#what-it-solves)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Architecture](#architecture)
- [Key Capabilities](#key-capabilities)
- [Explicit Non-Goals](#explicit-non-goals)
- [Roadmap](#roadmap)
- [License](#license)
- [Contributing](#contributing)
- [Contact](#contact)

---

## Why SmartAccess

A single `baseURL` is a single point of failure. Real-world iOS apps
running across regions, ISPs, and CDNs experience connectivity failures
at any layer of the network stack:

| Layer | Typical failure |
|---|---|
| DNS  | Local LDNS hijack, ISP poisoning, transient resolution failures |
| TCP  | CDN edge flapping, dropped at the border router, ISP egress issues |
| TLS  | Expired cert, on-path interception, client clock skew |
| HTTP | One CDN region down, origin overloaded, WAF false positives |

SmartAccess sits inside the client and continuously evaluates multiple
candidate paths. When one stage fails, it picks another path
automatically — and tells you **exactly which stage died** so your
on-call team can act.

## What it solves

- **Multi-domain failover** — `directDomain` / `backupDomain` / `relay`
  roles, cross-CDN policy configuration
- **DNS pollution resilience** — Concurrent system DNS / HTTPDNS / DoH
  / static-map resolution with stale-while-revalidate cache
- **Relay IP-direct fallback** — When a relay domain's DNS itself
  fails, SmartAccess can dial the resolved IP via `NWConnection` while
  preserving SNI, Host header, and certificate-by-hostname validation
- **Non-blocking cold start** — App gets a usable `baseURL` within
  ~25ms; full warmup races a 500ms timer in the background
- **Structured diagnostics** — Every failure is bucketed to a
  `ConnectivityStage` (dns / tcp / tls / http / ws); one-tap export
  produces a redacted diagnostic bundle for support
- **Self-healing telemetry** — SDK runtime has zero dependency on the
  telemetry sink; if your reporting channel is down, the main business
  path keeps failing over correctly
- **Sensitive-field redaction** — Authorization / Cookie / Token /
  Password fields can never enter the logs, enforced by unit tests
- **Signed policy distribution** — Ed25519-signed policies with
  monotonic versioning; rejects unsigned / replayed / tampered configs

---

## Installation

### Swift Package Manager

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/engineergxr-stack/SmartAccess.git",
             from: "2.0.0")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "SmartAccessCore", package: "SmartAccess")
    ])
]
```

Or in Xcode: **File → Add Packages…** and paste
`https://github.com/engineergxr-stack/SmartAccess.git`.

### Requirements

- iOS 15.0+
- Swift 5.7+ / Xcode 14+
- A customer-controlled HTTPS endpoint hosting `policy.signed.json`
- A signed `SmartAccess.license` file (request via
  [engineer.gxr@gmail.com](mailto:engineer.gxr@gmail.com) or sign one yourself
  for AGPL use)

---

## Quick Start

```swift
import SmartAccessCore

@main
struct YourApp: App {
    init() {
        Task.detached(priority: .userInitiated) {
            try? await Self.bootstrapSmartAccess()
        }
    }

    var body: some Scene { WindowGroup { ContentView() } }

    static func bootstrapSmartAccess() async throws {
        guard
            let licenseURL = Bundle.main.url(forResource: "SmartAccess",
                                              withExtension: "license"),
            let seedURL = Bundle.main.url(forResource: "SmartAccessSeedPolicy",
                                           withExtension: "signed.json")
        else { return }

        let base = SmartAccessConfig(
            projectId: "your_project_id",
            licenseFileURL: licenseURL,
            licensePublicKey: "<base64 ed25519 public key>",
            policyPublicKey:  "<base64 ed25519 public key>",
            seedPolicyFileURL: seedURL
        )
        // Enable on-device structured logging + diagnostic bundle export
        let config = SmartAccessConfig.withFileLogging(baseConfig: base)

        try await SmartAccess.shared.start(
            config: config,
            mode: .fastWarmup(maxWaitMs: 500)
        )
    }
}
```

Then in your network layer:

```swift
let baseURL = await SmartAccess.shared.currentBaseURL()
    ?? URL(string: "https://api-fallback.yourcompany.com")!

// After every request:
await SmartAccess.shared.reportSuccess(endpointId: "api-sg", latencyMs: 120)
await SmartAccess.shared.reportFailure(endpointId: "api-sg", error: err)
```

For Moya / Alamofire integration patterns, see
[`Docs/接入指南.md`](./Docs/接入指南.md).

### When all paths fail

You receive `SmartAccessError.noReachablePath(report:)`. The report
enumerates every attempted path and which `ConnectivityStage` it died
at — DNS, TCP, TLS, HTTP, or WS — so your team can locate the failure
mode in seconds:

```
- api-sg     directDomain  stage=dns  error=dns.lookup_failed
- api-hk     backupDomain  stage=tcp  error=tcp.connection_refused
- gateway-hk relay         stage=tls  error=tls.handshake_failed
```

---

## Architecture

```
SmartAccessCore/
├── SmartAccess.swift             Public facade
├── SmartAccessConfig.swift
├── SmartAccessStartupMode.swift  fastWarmup / fullWarmup / lazy
├── SmartAccessError.swift        Includes noReachablePath(report:)
│
├── Endpoint/                     Endpoint model + state + breaker
├── Connectivity/                 ConnectivityEngine (actor)
│                                 PathSelector (hysteresis, role weight,
│                                 auto-promote relay when direct fails
│                                 at DNS/TCP stage)
├── Health/                       HTTP & WebSocket probes
├── DNS/                          system (CFHost) / HTTPDNS / DoH /
│                                 static map + DNSCache with TTL
├── IPPool/                       NWConnection TCP+TLS diagnostics
├── Policy/                       Envelope + Resolver +
│                                 seed/cached/remote provider
├── License/                      Ed25519 verification + grace period
│                                 + feature gating
├── Security/                     SignatureVerifier (Curve25519
│                                 via CryptoKit)
├── Transport/                    V2: RelayDirectTransport +
│                                 TLSVerifier + HTTPParser
├── Integration/                  URLRewriter + URLRequestAdapter
├── Metrics/                      SAMetricsEvent (severity + batching)
├── Logging/                      SADiagnosticLog + FileLogStorage +
│                                 DiagnosticBundle + RedactionFilter
└── Utils/                        ErrorClassifier (NSError →
                                  ConnectivityStage)
```

**Concurrency model**: all stateful components are Swift `actor`s
(`ConnectivityEngine`, `EndpointManager`, `PolicyResolver`,
`DNSResolverManager`, `LicenseManager`). The public API is fully
`async/await`. Probes are `Sendable` value types that run inside
`Task.detached`.

**Trust boundary**: every endpoint, DNS resolver, IP pool, and circuit
breaker parameter comes from the signed `policy.json`. The SDK never
hard-codes endpoints and never reaches out to vendor infrastructure.

---

## Key Capabilities

### Five concurrent connectivity paths

| Path kind | Probe transport | Used for |
|---|---|---|
| `directDomain` | URLSession `/healthy` | Primary domain endpoint |
| `backupDomain` | URLSession `/healthy` | Secondary domain (different CDN/region) |
| `dnsResolved`  | DNSResolverManager diagnostic | Diagnostic-only (V1) |
| `staticIP`     | NWConnection TCP+TLS | Diagnostic-only (V1) |
| `relay`        | URLSession `/healthy` + optional NWConnection IP-direct | Customer-operated reverse proxy |

### PathSelector

```
score = role_weight × 100             // direct 1.0 > backup 0.6 > relay 0.4
      - EMA_latency / 40              // lower latency, higher score
      + min(20, consecutive_successes × 2)
      - priority × 0.1
breaker-open endpoints excluded.
```

10% hysteresis: a new path must score 10% higher than the current path
before switching, suppressing oscillation between two equally-good paths.

When all `direct`/`backup` paths die at `.dns` or `.tcp` stage,
relay weights are *temporarily* promoted to the same tier as direct —
relays are selected immediately, without waiting for retry accumulation.

### Circuit breaker + half-open probe

- `direct` / `backup`: trip threshold 2, open 60s (configurable per policy)
- `relay`: trip threshold 3, open 30s, **half-open probe** every 10s
- Once breaker expires, a synthetic probe runs first; real traffic only
  resumes if the probe succeeds.

### Self-healing telemetry

```swift
public protocol SAMetricsSink: Sendable {
    func emit(_ event: SAMetricsEvent)
    func emitBatch(_ events: [SAMetricsEvent])
}
```

The SDK ships events to a customer-provided sink (Sentry / Datadog /
in-house). No SmartAccess-controlled backend exists.

When `localLogStorage` is enabled, all events are also persisted locally
via a ring-buffered `FileLogStorage` (default 5 MB × 3 files). When a
user reports a problem, call:

```swift
let bundle = try await SmartAccess.shared.exportDiagnosticBundle()
// bundle.directory contains:
//   manifest.json      — SDK version, bundleId, projectId, policy version,
//                        masked license id, OS version
//   reachability.json  — last ReachabilityReport
//   logs.*.ndjson      — recent log files (rotated)
```

The bundle is automatically redacted: Authorization / Cookie /
Set-Cookie / X-Auth-Token / any field name matching the
`RedactionFilter` banlist is excluded. URLs are stripped of query
strings and userinfo. Unit tests enforce this.

---

## Explicit Non-Goals

| Topic | Position |
|---|---|
| **VPN / generic proxy / circumvention** | Not provided. Ever. |
| **Business-origin IP-direct** | Not done — iOS URLSession cannot override SNI/Host while preserving cert evaluation. Use multiple domain endpoints + a relay instead. |
| **SNI rewriting / protocol obfuscation** | Out of scope. This is what makes SmartAccess sellable to listed and multinational customers. |
| **Bypassing national/regional network regulation** | Refused at the customer onboarding stage. |
| **Hosting any traffic / gateway** | The SDK ships no service. Relays are customer-operated. |
| **HTTP/2 over NWConnection** | Not implemented. Business traffic uses URLSession, which negotiates HTTP/2 automatically. Relay IP-direct fallback uses HTTP/1.1. |
| **Auto-retry of non-idempotent requests** | POST/PUT are never retried by the SDK. Retry responsibility lives in the customer's business layer with idempotency keys. |
| **Background fetch / silent push** | Not requested. Warmup happens on foreground transitions. |

---

## Roadmap

| Item | Status |
|---|---|
| iOS V1 + V2 | Shipped |
| Android port (OkHttp + Cronet) | Planned. Architecture is platform-independent; estimated 4-6 person-months |
| HTTP/3 / QUIC transport | Researched. Will be layered on top of `NWProtocolQUIC` (iOS) / Cronet (Android), not hand-rolled |
| Adaptive retry (exponential backoff + jitter) | Under design. May extend the SDK boundary; currently retry is the customer's responsibility |
| Persistent `lastGoodPath` on disk | Planned for V2.1 — improves cold-start success rate |
| DNS cache persistence across app restarts | Planned for V2.1 |
| Happy Eyeballs (IPv4/IPv6 racing) | Planned for V2.2 |

Issues and PRs welcome — see [CONTRIBUTING.md](./CONTRIBUTING.md).

---

Run tests:

```sh
swift test
```

---

## License

**SmartAccess is dual-licensed.**

### Open-source use — AGPL-3.0

Free. Your application source must also be available under an AGPL-3.0-compatible license. This includes the case where you serve your app
to users over a network (SaaS). See [`LICENSE`](./LICENSE).

### Commercial use — Commercial License

Required if any of these apply to your project:

- Your app is closed-source / proprietary
- Your SaaS product cannot publish its full source
- You distribute on the App Store without disclosing your source
- You want priority support, SLA, or custom development

See [`LICENSE-COMMERCIAL.md`](./LICENSE-COMMERCIAL.md) for tiers and
contact details. Pricing starts at **USD 3,000/year** for startups.

### Which license do I need?

| Your situation | License |
|---|---|
| Open-source app under AGPL/GPL | AGPL-3.0 (free) |
| Open-source app under MIT/Apache | **Commercial** (AGPL forces your app to be AGPL, MIT is not compatible) |
| Closed-source app on App Store | **Commercial** |
| SaaS product with closed source | **Commercial** |
| Research, academic, evaluation | AGPL-3.0 (free) |

---

## Contributing

By submitting a pull request you agree to license your contribution
under AGPL-3.0 **and** grant the maintainer the right to sub-license
your contribution under the commercial license. This is the standard
dual-licensing CLA model.

See [`CONTRIBUTING.md`](./CONTRIBUTING.md) for full terms and what we
welcome / will not merge.

---

## Contact

- Email: [engineer.gxr@gmail.com](mailto:engineer.gxr@gmail.com)
- Issues: [github.com/engineergxr-stack/SmartAccess/issues](https://github.com/engineergxr-stack/SmartAccess/issues)
- Discussions: [github.com/engineergxr-stack/SmartAccess/discussions](https://github.com/engineergxr-stack/SmartAccess/discussions)

For commercial licensing inquiries, please include in your email:

1. Company name and country of registration
2. Intended use (product description, distribution channels)
3. Estimated number of monthly active users
4. Target start date

Response within 2 business days.
