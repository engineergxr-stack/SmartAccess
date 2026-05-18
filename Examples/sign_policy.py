#!/usr/bin/env python3
"""
本脚本用客户私钥对 policy / license 做 Ed25519 签名。

依赖: pip install pynacl
用法:
  python3 sign_policy.py policy_unsigned.json private_key.bin > policy.signed.json

签名规则（务必和 SDK 端保持一致）:
  - 取 envelope 中的 "policy" 子对象（或 "license"）
  - 用 json.dumps(..., sort_keys=True, separators=(",", ":"))? 不!
    SDK 端用 JSONSerialization.data(withJSONObject:..., options: [.sortedKeys])
    它保留默认 spacing。Python 端用 json.dumps(..., sort_keys=True) (默认 separators) 即可对齐字节。
    保险起见，调用方应同时记录 canonical_bytes 的 sha256 和 SDK 端做交叉验证。
"""
import sys
import json
import base64

from nacl.signing import SigningKey

def canonical_bytes(obj) -> bytes:
    # Apple JSONSerialization.data(..., options: [.sortedKeys]) 默认输出紧凑、无空格的 JSON。
    # 这里用同样的紧凑分隔符 + sort_keys=True 对齐字节流。
    # 注意点：
    #   1) 所有时间戳用整数（不要用 1.76e9 这种科学计数）；
    #   2) 不要在 JSON 里出现非 ASCII 字符（如必要，提前 ensure_ascii=True / 转义）；
    #   3) 不要出现 NaN / Infinity。
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")

def main():
    if len(sys.argv) != 3:
        print("usage: sign_policy.py <unsigned.json> <private_key.bin>", file=sys.stderr)
        sys.exit(2)
    with open(sys.argv[1], "rb") as f:
        envelope = json.load(f)
    with open(sys.argv[2], "rb") as f:
        priv = f.read()
    if len(priv) != 32:
        print("private key must be 32 bytes Ed25519 seed", file=sys.stderr)
        sys.exit(2)

    if "policy" in envelope:
        body_key = "policy"
    elif "license" in envelope:
        body_key = "license"
    else:
        print("expected 'policy' or 'license' key", file=sys.stderr)
        sys.exit(2)

    body = envelope[body_key]
    cb = canonical_bytes(body)
    sig = SigningKey(priv).sign(cb).signature
    envelope["signature"] = base64.b64encode(sig).decode("ascii")

    json.dump(envelope, sys.stdout, ensure_ascii=False, indent=2)

if __name__ == "__main__":
    main()
