#!/usr/bin/env bash
# 阿里云 106.14.250.186 站点部署脚本
#   拉 GitHub main → 校验 → 发到 releases/<ts> → 切 current → reload nginx → 验收
# 设计约束：幂等 / 不删现网 / 旧版保留可回滚 / 失败自动回滚
# 用法（服务器上）：
#   bash -c "$(curl -sSL https://raw.githubusercontent.com/xujun105-cell/ai-seo-website/ops/deploy_aliyun.sh)"
set -euo pipefail

REPO="https://github.com/xujun105-cell/ai-seo-website.git"
BASE="${XLD_BASE:-/var/www/aiqiangban}"
TS="$(date +%Y%m%d-%H%M%S)"
REL="$BASE/releases/$TS"
SKIP_SYSTEM="${XLD_SKIP_SYSTEM:-0}"

log(){ echo "[deploy] $*"; }
fail(){ echo "[deploy][FAIL] $*"; exit 1; }

# ---------- 0. 部署前：看清现场（不改任何东西）----------
log "=== 0/6 现场勘察 ==="
log "base 目录: $(ls -ld "$BASE" 2>/dev/null || echo '不存在')"
if [ -e "$BASE/current" ]; then
  log "current 类型: $([ -L "$BASE/current" ] && echo '软链 →'$(readlink "$BASE/current") || echo '实目录')"
else
  log "current: 不存在"
fi
log "已有 releases: $(ls -1dt "$BASE"/releases/* 2>/dev/null | head -3 | tr '\n' ' ')"
if command -v nginx >/dev/null 2>&1; then
  log "nginx 配置摘要:"
  nginx -T 2>/dev/null | grep -E "^\s*(root|server_name|listen)" | sed 's/^/    /' | head -20 || true
fi
log "git 版本: $(git --version 2>/dev/null || echo '缺失')"

# ---------- 1. 拉取 main ----------
log "=== 1/6 拉取 main ==="
mkdir -p "$BASE/releases"
git clone --depth 1 "$REPO" "$REL" || fail "clone 失败（网络或仓库不可达）"
log "  HEAD: $(cd "$REL" && git log --oneline -1)"

# ---------- 2. 完整性校验 ----------
log "=== 2/6 完整性校验 ==="
for f in index.html sitemap.xml robots.txt; do
  [ -s "$REL/$f" ] || fail "缺失 $f —— 中止，现网未动"
  log "  ✅ $f $(wc -c < "$REL/$f") bytes"
done
# 注意：仓库 sitemap 用 ns0: 命名空间前缀（<ns0:loc>），校验必须命名空间无关
grep -qE "<([a-zA-Z0-9]+:)?urlset" "$REL/sitemap.xml" || fail "sitemap.xml 结构异常 —— 中止"
URLN=$(grep -oE "<([a-zA-Z0-9]+:)?loc>" "$REL/sitemap.xml" | wc -l | tr -d " ")
[ "$URLN" -gt 100 ] || fail "sitemap URL 数为 $URLN，异常偏少 —— 中止，现网未动"
log "  sitemap URL 数: $URLN"

# ---------- 3. 切换 current（保留旧版）----------
log "=== 3/6 切换 current ==="
PREV=""
if [ -L "$BASE/current" ]; then
  PREV="$(readlink "$BASE/current")"
  ln -sfn "$REL" "$BASE/current.tmp" && mv -Tf "$BASE/current.tmp" "$BASE/current"
  log "  软链切换: $PREV → $REL"
elif [ -d "$BASE/current" ]; then
  PREV="$BASE/releases/prev-$TS"
  mv "$BASE/current" "$PREV"
  mkdir -p "$BASE/current"
  cp -a "$REL/." "$BASE/current/"
  log "  实目录备份为 $PREV，同步新内容进 current"
else
  mkdir -p "$BASE/current"
  cp -a "$REL/." "$BASE/current/"
  log "  首次创建 current"
fi

# ---------- 4. nginx ----------
log "=== 4/6 nginx ==="
if [ "$SKIP_SYSTEM" = "1" ]; then
  log "  (DRY-RUN: 跳过 nginx)"
elif command -v nginx >/dev/null 2>&1; then
  nginx -t || { log "nginx 配置测试失败 —— 回滚"; [ -n "$PREV" ] && ln -sfn "$PREV" "$BASE/current"; exit 1; }
  systemctl reload nginx && log "  nginx reloaded"
else
  log "  nginx 未安装，跳过"
fi

# ---------- 5. 验收 ----------
log "=== 5/6 验收 ==="
probe(){ curl -s -o /dev/null -w "%{http_code} %{size_download}B" -m 10 "$1" 2>/dev/null || echo "ERR"; }
log "  /healthz     → $(probe http://127.0.0.1/healthz)"
log "  /            → $(probe http://127.0.0.1/)"
log "  /sitemap.xml → $(probe http://127.0.0.1/sitemap.xml)"
log "  /robots.txt  → $(probe http://127.0.0.1/robots.txt)"
QURL="http://127.0.0.1/qna/%E8%8B%8F%E5%B7%9E%E5%A3%81%E6%9D%BF%E5%8E%82%E5%AE%B6%E5%93%AA%E5%AE%B6%E5%A5%BD.html"
if command -v python3 >/dev/null 2>&1; then
  CN=$(curl -s -m 10 "$QURL" | python3 -c "import sys,re;h=sys.stdin.read();t=re.sub(r'<[^>]+>','',h);print(len(re.findall(r'[\u4e00-\u9fff]',t)))" 2>/dev/null || echo "?")
  log "  qna《苏州墙板厂家哪家好》中文字数 → $CN"
else
  log "  (无 python3，跳过中文字数检查)"
fi

# ---------- 6. 收尾 ----------
log "=== 6/6 保留版本（可回滚）==="
ls -1dt "$BASE"/releases/* 2>/dev/null | head -5 | sed 's/^/  /'
log "回滚: ln -sfn <上面的目录> $BASE/current && systemctl reload nginx"
log "DONE ✅ 部署完成，本地端口已验收"
