#!/usr/bin/env bash
# xld_tls_and_deploy.sh -- 优家美站点 (aiqiangban.com) 服务器侧一次完成
#   0) 现状快照 (nginx -T / ss -lntp / letsencrypt / 本机 curl 自测) = TLS 三连诊断
#   1) 缺证书时用 DNS-01 签发 (certbot + certbot-dns-aliyun, 阿里云 hichina DNS)
#   2) 执行 SHA 锁定的部署 (新构建不含 MEMORY.md/TOOLS.md/.git, 并原子切 current)
#   3) 补 listen 443 ssl + 证书链 (备份 + nginx -t 校验 + 失败自动回滚)
#   4) 清理站点根里残留的内部文件与 .git (凭据/内部资料已公开, 必须清)
#   5) 验收: 敏感路径必须非 200, 打印部署最后 20 行
#
# 用法 (服务器 root):
#   bash -c "$(curl -sSL https://raw.githubusercontent.com/xujun105-cell/ai-seo-website/<SHA>/deploy/xld_tls_and_deploy.sh)"
#
# 环境变量:
#   ALICLOUD_ACCESS_KEY_ID / ALICLOUD_ACCESS_KEY_SECRET  -- 签发证书用 (或 /root/.aliyun/dns.ini)
#   XLD_EMAIL                -- certbot 注册邮箱
#   XLD_BASE                 -- 站点根, 默认 /var/www/aiqiangban
#   XLD_DRY_RUN=1            -- 只打印不改动, 用于演练
set -uo pipefail

DOMAIN="aiqiangban.com"
WWW="www.aiqiangban.com"
CERT_NAME="aiqiangban.com"
DEPLOY_SHA="47578e5bfc0a6a344d61013a9013bb27bc3f245d"
BASE="${XLD_BASE:-/var/www/aiqiangban}"
RAW="https://raw.githubusercontent.com/xujun105-cell/ai-seo-website"
CODELOAD="https://codeload.github.com/xujun105-cell/ai-seo-website/tar.gz"
REPO_API="https://api.github.com/repos/xujun105-cell/ai-seo-website"
WORK="/tmp/xld_tls_$(date +%Y%m%d-%H%M%S)"
DRY="${XLD_DRY_RUN:-0}"

# fetch_repo_file: raw -> contents API -> codeload tarball 三级回退
# raw CDN 对新路径可能 404 (本项目实测过), 不能只靠 raw
fetch_repo_file(){
  local sha="$1" path="$2" out="$3"
  if curl -fsSL --max-time 30 -o "$out" "$RAW/$sha/$path" 2>/dev/null && [ -s "$out" ]; then
    return 0
  fi
  log "raw 取不到 $path, 改用 contents API"
  rm -f "$out"
  if curl -fsSL --max-time 30 -o "$out.json" "$REPO_API/contents/$path?ref=$sha" 2>/dev/null; then
    if python3 -c 'import base64,json,sys;d=json.load(open(sys.argv[1]));open(sys.argv[2],"wb").write(base64.b64decode(d["content"]))' "$out.json" "$out" 2>/dev/null && [ -s "$out" ]; then
      return 0
    fi
  fi
  log "contents API 取不到, 改用 codeload tarball"
  rm -f "$out"
  curl -fsSL --max-time 120 -o "$WORK/repo.tar.gz" "$CODELOAD/$sha" 2>/dev/null
  tar xz -f "$WORK/repo.tar.gz" -C "$WORK" --wildcards "*/$path" 2>/dev/null
  local found
  found="$(find "$WORK" -path "*/$path" -type f 2>/dev/null | head -1)"
  if [ -n "$found" ]; then
    cp -f "$found" "$out"
    return 0
  fi
  return 1
}

log(){ echo "[tls-deploy] $*"; }
step(){ echo ""; echo "================ $* ================"; }
dry(){ if [ "$DRY" = "1" ]; then echo "[DRY-RUN] $*"; return 0; fi; return 1; }

step "0. 现状快照 (TLS 三连诊断)"
echo "  host=$(hostname)  whoami=$(whoami)  date=$(date "+%Y-%m-%dT%H:%M:%S%z")  dry=$DRY"
if command -v nginx >/dev/null 2>&1; then
  log "--- nginx -T: listen / ssl_certificate / server_name ---"
  nginx -T 2>/dev/null | grep -nE "listen |ssl_certificate|server_name" | head -60
  log "--- 443 监听块计数 ---"
  nginx -T 2>/dev/null | grep -cE "listen .*443" || true
  log "--- nginx root 取值 ---"
  nginx -T 2>/dev/null | grep -oE "root[[:space:]]+[^;]+;" | sed "s/root[[:space:]]*//;s/;$//" | sort -u | sed "s/^/    /"
else
  log "nginx 未安装"
fi
log "--- 谁在监听 80/443 (判定 443 是本机 nginx 还是边缘层) ---"
(ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null) | grep -E ":(80|443) " | sed "s/^/    /" || echo "    (无 ss/netstat 结果)"
log "--- /etc/letsencrypt/live ---"
ls -la /etc/letsencrypt/live/ 2>/dev/null || echo "  (无)"
command -v certbot >/dev/null 2>&1 && certbot --version 2>&1 | sed "s/^/  /" || echo "  certbot 未安装"
log "--- 本机自测 ---"
curl -s -o /dev/null -w "  http://127.0.0.1/ code=%{http_code} size=%{size_download}\n" --max-time 8 "http://127.0.0.1/" || echo "  80 本机无响应"
curl -k -s -o /dev/null -w "  https://127.0.0.1/ code=%{http_code}\n" --max-time 8 "https://127.0.0.1/" || echo "  443 本机无响应"
log "--- 磁盘 ---"
df -h / | tail -1

step "1. 判断是否需要签发证书"
NEED_CERT="no"
if command -v nginx >/dev/null 2>&1 && nginx -T 2>/dev/null | grep -qE "listen .*443"; then
  if [ -f "/etc/letsencrypt/live/$CERT_NAME/fullchain.pem" ]; then
    log "已有 443 监听且证书在位 -- 跳过签发"
  else
    log "有 443 监听但证书缺失 -- 需要签发"
    NEED_CERT="yes"
  fi
else
  log "本机 nginx 无 443 监听 -- 需要签发证书 (443 也可能由边缘层接管, 证书先备好)"
  NEED_CERT="yes"
fi

if [ "$NEED_CERT" = "yes" ]; then
  step "2. DNS-01 签发证书 (不依赖 80/443, ICP 未备案也能先备好)"
  AK="${ALICLOUD_ACCESS_KEY_ID:-}"
  SK="${ALICLOUD_ACCESS_KEY_SECRET:-}"
  INI="/root/.aliyun/dns.ini"
  if { [ -z "$AK" ] || [ -z "$SK" ]; } && [ -f "$INI" ]; then
    AK="$(grep -E "^dns_aliyun_access_key " "$INI" | head -1 | cut -d= -f2- | tr -d " ")"
    SK="$(grep -E "^dns_aliyun_access_key_secret " "$INI" | head -1 | cut -d= -f2- | tr -d " ")"
  fi
  if [ -z "$AK" ] || [ -z "$SK" ]; then
    log "缺少阿里云 AK/SK -- 证书步骤跳过 (部署与清理不受影响)"
    log "  补齐方式: export ALICLOUD_ACCESS_KEY_ID=... ALICLOUD_ACCESS_KEY_SECRET=... 后重跑本脚本"
  elif dry "certbot certonly --dns-aliyun -d $DOMAIN -d $WWW"; then
    log "演练模式, 不实际签发"
  else
    command -v certbot >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq certbot >/dev/null 2>&1; }
    python3 -m pip install --quiet --upgrade certbot-dns-aliyun >/dev/null 2>&1 || python3 -m pip install --quiet --break-system-packages --upgrade certbot-dns-aliyun >/dev/null 2>&1
    mkdir -p /root/.aliyun
    umask 077
    { echo "dns_aliyun_access_key = $AK"; echo "dns_aliyun_access_key_secret = $SK"; } > "$INI"
    MAILARG="--register-unsafely-without-email"
    if [ -n "${XLD_EMAIL:-}" ]; then MAILARG="-m ${XLD_EMAIL}"; fi
    log "certbot 开始签发 (DNS-01, $DOMAIN + $WWW)"
    certbot certonly --non-interactive --agree-tos $MAILARG --dns-aliyun --dns-aliyun-credentials "$INI" --dns-aliyun-propagation-seconds 60 -d "$DOMAIN" -d "$WWW" 2>&1 | tail -20
  fi
fi

step "3. 执行 SHA 锁定的部署 (新构建不含敏感文件, 原子切 current)"
SHA="$(curl -s --max-time 20 https://api.github.com/repos/xujun105-cell/ai-seo-website/commits/ops | python3 -c 'import sys,json;print(json.load(sys.stdin).get("sha",""))' 2>/dev/null)"
[ -n "$SHA" ] || SHA="$DEPLOY_SHA"
log "锁定 SHA = $SHA"
DEPLOY_LOG="$WORK/deploy.log"
mkdir -p "$WORK"
fetch_repo_file "$SHA" "deploy/deploy_aliyun.sh" "$WORK/deploy_aliyun.sh" || log "部署脚本下载失败"
if [ -s "$WORK/deploy_aliyun.sh" ]; then
  if dry "bash $WORK/deploy_aliyun.sh"; then
    log "演练模式, 不实际部署"
  else
    bash "$WORK/deploy_aliyun.sh" 2>&1 | tee "$DEPLOY_LOG"
    log "部署退出码 ${PIPESTATUS[0]}"
  fi
else
  log "部署脚本不可用, 跳过"
fi

step "4. 补 443 配置 + 证书链 (备份, nginx -t 校验, 失败自动回滚)"
fetch_repo_file "$SHA" "deploy/patch_nginx_tls.py" "$WORK/patch_nginx_tls.py" || log "patcher 下载失败"
if [ -s "$WORK/patch_nginx_tls.py" ] && [ -f "/etc/letsencrypt/live/$CERT_NAME/fullchain.pem" ]; then
  if dry "patch_nginx_tls.py"; then
    log "演练模式, 不改 nginx"
  else
    python3 "$WORK/patch_nginx_tls.py" --cert-name "$CERT_NAME" --domain "$DOMAIN" --fallback-root "$BASE/current" --work "$WORK" 2>&1 | tail -30
    if command -v nginx >/dev/null 2>&1; then
      nginx -t >"$WORK/nginx_t.log" 2>&1
      RC=$?
      tail -3 "$WORK/nginx_t.log"
      if [ "$RC" = "0" ]; then
        systemctl reload nginx && log "nginx reloaded" || log "reload 失败"
      else
        log "nginx -t 失败 -- 从备份回滚"
        if [ -f "$WORK/backup_manifest.txt" ]; then
          while IFS="|" read -r orig bak; do cp -f "$bak" "$orig" && log "  已回滚 $orig"; done < "$WORK/backup_manifest.txt"
          nginx -t >/dev/null 2>&1 && systemctl reload nginx && log "回滚后 nginx 正常"
        fi
      fi
    fi
  fi
else
  log "跳过 443 配置 (无 patcher 或无证书)"
fi

step "5. 清理站点根里残留的敏感文件 (凭据已公开, 必须清)"
if [ -d "$BASE" ]; then
  FOUND="$(find "$BASE" -maxdepth 3 \( -name "MEMORY.md" -o -name "TOOLS.md" -o -name "AGENTS.md" -o -name "SOUL.md" -o -name "USER.md" -o -name "IDENTITY.md" -o -name "HEARTBEAT.md" -o -name ".git" -o -name ".openclaw" -o -name "_internal" -o -name "memory" -o -name "deploy" -o -name "apply_optimization.sh" -o -name "ai-platform-guide.md" -o -name "外链建设方案.md" -o -name "百度爱采购注册内容.md" \) 2>/dev/null | head -80)"
  if [ -n "$FOUND" ]; then
    echo "$FOUND" | while IFS= read -r P; do echo "    命中 $P"; done
    if dry "remove sensitive files under $BASE"; then
      log "演练模式, 不删除"
    else
      echo "$FOUND" | while IFS= read -r P; do rm -rf "$P" && echo "    已移除 $P"; done
    fi
  else
    log "站点根下无敏感文件残留"
  fi
  LEFT="$(find "$BASE" -maxdepth 3 \( -name "MEMORY.md" -o -name "TOOLS.md" -o -name ".git" -o -name ".openclaw" -o -name "apply_optimization.sh" \) 2>/dev/null | head -20)"
  if [ -n "$LEFT" ]; then log "WARN 清理后仍有残留:"; printf "%s\n" "$LEFT" | sed "s/^/      /"; else log "清理后复检: 无残留"; fi
else
  log "无 $BASE 目录"
fi

step "6. 验收"
for P in /MEMORY.md /TOOLS.md /AGENTS.md /SOUL.md /USER.md /IDENTITY.md /HEARTBEAT.md /.git/config /.git/index /.git/HEAD /.openclaw/workspace-state.json /apply_optimization.sh /ai-platform-guide.md /_internal/ /memory/ /deploy/; do
  CODE="$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://127.0.0.1$P" 2>/dev/null)"
  if [ "$CODE" = "200" ]; then log "FAIL $P -> $CODE (仍公开, 必须修)"; else log "OK   $P -> $CODE"; fi
done
log "--- 中文名内部文件磁盘复检 ---"
for F in "外链建设方案.md" "百度爱采购注册内容.md"; do
  if [ -e "$BASE/$F" ]; then log "FAIL $F 仍存在"; else log "OK   $F 已清除"; fi
done
log "--- 首页与 sitemap ---"
curl -s -o /dev/null -w "  http://127.0.0.1/ code=%{http_code} size=%{size_download}\n" --max-time 10 "http://127.0.0.1/"
echo "  sitemap.xml loc=$(curl -s --max-time 15 "http://127.0.0.1/sitemap.xml" | grep -c "<loc>")"
echo "  sitemap-ai.xml loc=$(curl -s --max-time 15 "http://127.0.0.1/sitemap-ai.xml" | grep -c "<loc>")"
log "--- HTTPS 自测 ---"
curl -k -s -o /dev/null -w "  https://127.0.0.1/ code=%{http_code}\n" --max-time 10 "https://127.0.0.1/" || true

step "7. 部署脚本最后 20 行"
if [ -f "$DEPLOY_LOG" ]; then tail -20 "$DEPLOY_LOG"; else log "无部署日志 (演练模式或部署未执行)"; fi
log "工作目录: $WORK"
