#!/usr/bin/env bash
#
# install.sh —— 下载 BaiduPCS-Go 到 ./bin/
#
# BaiduPCS-Go 是第三方开源项目（qjfoidnh/BaiduPCS-Go），
# 二进制不入库，用这个脚本按需下载。
#
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="qjfoidnh/BaiduPCS-Go"
VERSION="${1:-latest}"

# ---------------------------------------------------------------- 平台探测
os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Linux)  goos=linux ;;
  Darwin) goos=darwin ;;
  *) echo "不支持的系统: $os" >&2; exit 1 ;;
esac
case "$arch" in
  x86_64|amd64) goarch=amd64 ;;
  aarch64|arm64) goarch=arm64 ;;
  i386|i686) goarch=386 ;;
  *) echo "不支持的架构: $arch" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------- 解析版本
if [ "$VERSION" = latest ]; then
  echo "查询最新版本..."
  VERSION="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -m1 '"tag_name"' | cut -d'"' -f4)"
  [ -n "$VERSION" ] || { echo "查询失败，手动指定版本: ./install.sh v4.0.1" >&2; exit 1; }
fi
echo "版本: $VERSION  平台: $goos-$goarch"

ASSET="BaiduPCS-Go-$VERSION-$goos-$goarch.zip"
URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"

# ---------------------------------------------------------------- 下载解压
command -v unzip >/dev/null || { echo "错误: 需要 unzip，先装一下" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "下载 $URL"
curl -fL --progress-bar -o "$tmp/pcs.zip" "$URL"
unzip -oq "$tmp/pcs.zip" -d "$tmp"

bin="$(find "$tmp" -name 'BaiduPCS-Go' -type f | head -1)"
[ -n "$bin" ] || { echo "错误: 压缩包里没找到二进制" >&2; exit 1; }

mkdir -p "$BASE/bin"
install -m 0755 "$bin" "$BASE/bin/BaiduPCS-Go"

echo
echo "✓ 装好了: $BASE/bin/BaiduPCS-Go"
"$BASE/bin/BaiduPCS-Go" -v
echo
cat <<'NEXT'
下一步 —— 登录（需要 BDUSS 和 STOKEN 两个 cookie，缺一不可）:

  1. 浏览器登录 pan.baidu.com，停在网盘页面
  2. F12 → Application → Cookies → https://pan.baidu.com
  3. 分别点中 BDUSS 和 STOKEN 两行，从下方 Value 面板复制完整值
     （别从表格单元格里拖选，长值会被截断）
  4. ./bin/BaiduPCS-Go login -bduss="..." -stoken="..."
  5. ./bin/BaiduPCS-Go who      验证

STOKEN 只挂在 pan.baidu.com 域下，当前页得是网盘页面才看得到。

这两个值等同于账号凭证，别贴进聊天窗口、别提交进 git、别写进脚本。
NEXT
