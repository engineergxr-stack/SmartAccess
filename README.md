# SmartAccess iOS SDK (Core)

> 客户端连接路径选择与可达性保障 SDK。
>
> **不是** VPN、不是通用代理、不是托管 Gateway、不是任意 URL/IP 转发。

只服务客户自有或已授权的 endpoint。所有 endpoint 必须来自客户自托管的 **已签名 policy**。

## 平台与最低版本

- iOS 15+
- Swift 5.7+
- 公共 API 全部基于 `async/await`

## 集成

把这个目录作为 Swift Package 引入，或直接拷贝 `Sources/SmartAccessCore`。

```swift
.package(path: "../SmartAccess-iOS")
```

然后在 target 里依赖 `SmartAccessCore`。

## 使用

```swift
import SmartAccessCore

let config = SmartAccessConfig(
    projectId: "customer_app",
    licenseFileURL: Bundle.main.url(forResource: "SmartAccess", withExtension: "license")!,
    licensePublicKey: "<base64 ed25519 public key>",
    policyPublicKey:  "<base64 ed25519 public key>",
    seedPolicyFileURL: Bundle.main.url(forResource: "SmartAccessSeedPolicy", withExtension: "signed.json")
)

try await SmartAccess.shared.start(config: config, mode: .fastWarmup(maxWaitMs: 500))

// 业务网络层取 baseURL
let baseURL = await SmartAccess.shared.currentBaseURL()

// 每次请求返回后回写
await SmartAccess.shared.reportSuccess(endpointId: "api-sg", latencyMs: 120)
await SmartAccess.shared.reportFailure(endpointId: "api-sg", error: someError)
```

### Moya / Alamofire

```swift
struct CustomerTarget: TargetType {
    var baseURL: URL { /* 同步桥：在主线程缓存最近一次 currentBaseURL 即可 */ ... }
}
```

Moya / Alamofire 因为是同步取 baseURL，建议你在 SmartAccess 启动完成后，把 `currentBaseURL` 缓存到一个 `@MainActor` 的容器里，并在 `pathChanged` metrics 事件回调中刷新。

## Policy / License

- Policy / License 都用 Ed25519 签名。
- Policy 必须由客户在自己后台签发，并通过 **客户自托管 URL** 下发。
- License 内嵌在客户 App Bundle 里，离线即可校验。
- SDK 不会托管任何 Gateway，也不会把请求转发到非客户授权的 endpoint。

## 边界（请反复确认）

- 不做 VPN、代理、翻墙；
- 不优化任何第三方服务（Firebase / Apple API / Stripe 等）；
- 不保证业务成功率（登录、下单、支付、提现）；
- 不托管业务 WebSocket（只做 connect check）；
- 不关闭 TLS 校验，不接管 cookie / cache。

详细禁止用途见随交付的 `安全边界说明.md`、`禁止用途条款.md`。

## 测试

```sh
swift test
```

## 目录结构

```
Sources/SmartAccessCore/
  SmartAccess.swift
  SmartAccessConfig.swift
  SmartAccessStartupMode.swift
  SmartAccessError.swift
  Endpoint/
  Connectivity/
  Health/
  DNS/
  IPPool/
  Policy/
  License/
  Security/
  Integration/
  Metrics/
  Utils/
Tests/SmartAccessCoreTests/
```
