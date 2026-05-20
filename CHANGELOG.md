# CHANGELOG

## 2.0.0-beta.1 — Relay 强化 + 日志出口 + HTTPDNS 生产模式

### 新增

- **日志出口**：
  - `SAMetricsEvent` 加 `severity` / 多个 Relay 失败 / 熔断事件
  - `FilteredMetricsSink` 按严重度过滤
  - `SADiagnosticLog` 结构化日志条目
  - `FileLogStorage` 环形文件存储（默认 5 MB × 3）
  - `DiagnosticBundle` 一键导出 manifest + reachability + 日志
  - `RedactionFilter` banlist，禁止 Authorization / Cookie / Token / Password 字段进入日志
  - `SmartAccess.shared.exportDiagnosticBundle()` 公共 API
  - `SmartAccess.shared.purgeLocalLogs()` 公共 API

- **Relay 强化**：
  - `SAEndpoint` 加 `group` / `directIPMode`
  - `SmartAccessPolicy` 加 `relay_circuit_breaker` / `relay_failover_strategy`
  - Relay 用独立熔断参数（failureThreshold=3 / openSeconds=30 / half-open probe）
  - PathSelector 在 direct/backup 全死于 dns/tcp 阶段时**自动把 Relay 提到与 direct 同权**
  - `relayFailoverStrategy: nearest / roundRobin / weighted`
  - Half-open probe：熔断到期后先发探针再放真实流量
  - 新事件：`relaySelectedAsFailover` / `relayPromoted` / `circuitBreakerOpened` / `circuitBreakerHalfOpenProbed`

- **HTTPDNS 生产模式**：
  - `DNSCache` 带 TTL 缓存，支持 stale-while-revalidate
  - `DNSResolverManager.resolveForProduction(host:)` 返回单一权威 IP 列表
  - `DNSResolverManager.prewarm(hosts:)` 启动期预热 Relay host
  - V1 诊断模式仍可用（`diagnostic_only: true`）

- **Relay IP 直连**（V2 核心）：
  - `Transport/TLSVerifier` — SecPolicyCreateSSL(true, hostname) 重新校验 + 可选 SPKI pinning
  - `Transport/HTTPParser` — 极简 HTTP/1.1 响应解析（Content-Length / chunked）
  - `Transport/RelayDirectTransport` — NWConnection-based HTTP/1.1 客户端，强制 SNI/Host = hostname
  - `Transport/RelayPathResolver` — 决定是否走 IP 直连 + 选 IP
  - `SmartAccess.shared.shouldUseRelayDirect()` / `sendViaRelayDirect(...)` 公共 API
  - **业务源站永远不会走 IP 直连**，只对 Relay endpoint 启用

- **ReachabilityReport 升级**：
  - 加 `selection` 字段含选中原因
  - 加 `dnsSnapshots` 字段（每个 host 的当前 DNS 结果）
  - 加 `group` 维度（按 endpoint group 分组）

- **文档**：
  - `Docs/SOP-CustomerRelay.md` — nginx / Caddy 配置 + 证书 + 合规免责
  - `Docs/SOP-V2-Launch-Checklist.md` — 客户上线 V2 前 Checklist

### 修改

- `SmartAccessVersion.current` → `2.0.0-beta.1`
- `EndpointManager.init(...)` 加 `relayBreakerConfig` 参数
- `PathSelector.selectBest(...)` 返回 `(path, reason)` 元组并改为 `mutating`
- V1 集成代码兼容：原有 `currentBaseURL()` / `reportSuccess` / `reportFailure` 行为不变

### 兼容性

V1 (1.0.0) policy.json 在 V2 SDK 下**完全兼容**：

- 缺少 `relay_circuit_breaker` → 用默认值
- 缺少 `relay_failover_strategy` → 默认 nearest
- endpoint 缺少 `group` / `direct_ip_mode` → relay 默认 `fallback`，其他默认 `off`

V1 集成代码（仅使用 `currentBaseURL()`）在 V2 下无需改动。
若想启用 Relay IP 直连，客户网络层需调 `shouldUseRelayDirect()` 路径，详见 `README.md`。

## 1.0.0 — Initial release

详见 `git log v1.0.0`。
