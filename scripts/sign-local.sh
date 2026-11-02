#!/bin/bash
#
# sign-local.sh
# Ice
#
# 用本机固定的自签名身份重签 Ice.app。
#
# 为什么要重签：CI 产出的 nightly 未签名，macOS 会把辅助功能/屏幕录制权限
# 绑定到二进制哈希(cdhash)，每次更新都会失效。用固定证书重签后，TCC 认的是
# "identifier + 证书"，更新后权限继续有效，只需重跑本脚本。
#
# 用法: scripts/sign-local.sh [App 路径]
#
set -euo pipefail

APP="${1:-/Applications/Ice.app}"
IDENTITY="${ICE_SIGN_IDENTITY:-Mac Local Self Signed}"
KEYCHAIN="${ICE_SIGN_KEYCHAIN:-$HOME/.config/mac-selfsign/signing/mac-selfsign.keychain-db}"
PASSWORD_FILE="${ICE_SIGN_PASSWORD_FILE:-$HOME/.config/mac-selfsign/signing/keychain-password}"

if [[ ! -d "$APP" ]]; then
    echo "error: 未找到 $APP" >&2
    exit 1
fi

if [[ ! -f "$KEYCHAIN" ]]; then
    echo "error: 未找到签名钥匙串 $KEYCHAIN" >&2
    exit 1
fi

if [[ ! -f "$PASSWORD_FILE" ]]; then
    echo "error: 未找到钥匙串密码文件 $PASSWORD_FILE" >&2
    exit 1
fi

if ! security find-identity -v -p codesigning "$KEYCHAIN" | grep -qF "$IDENTITY"; then
    echo "error: 钥匙串中找不到可用的签名身份: $IDENTITY" >&2
    exit 1
fi

security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN"

# 去掉下载隔离标记，避免自签名后被 Gatekeeper 拦截。
xattr -cr "$APP" 2>/dev/null || true

codesign --force --deep --timestamp=none \
    --identifier com.jordanbaird.Ice \
    -s "$IDENTITY" "$APP"

codesign --verify --deep --strict --verbose=1 "$APP"

echo
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|Info.plist"
codesign -d -r- "$APP" 2>&1 | tail -1

echo
echo "如需首次切换到该签名身份，请先重置一次权限再重新授权:"
echo "  tccutil reset Accessibility com.jordanbaird.Ice"
echo "  tccutil reset ScreenCapture com.jordanbaird.Ice"
