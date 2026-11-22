#!/usr/bin/env bash
# 阿里云站点部署脚本（在目标服务器上执行）
#   拉 GitHub main → 导出干净站点 → 校验 → 发到 releases/<ts> → 原子切 current → reload nginx → 字节级验收
#
# 设计约束：
#   幂等 / 不删现网 / 旧版保留可回滚 / 失败自动回滚 / 站点目录不含 .git 与内部文件
#   不硬编码任何主机地址（仓库公开，避免新增暴露面）
#
# 环境变量：
#   XLD_BASE        站点根目录（默认 /var/www/aiqiangban）
#   XLD_REPO        仓库地址
#   XLD_HOST        用于验收的域名（默认 aiqiangban.com）
#   XLD_SKIP_SYSTEM=1  干跑：跳过 nginx reload
#   XLD_EXCLUDE     额外排除的 glob（空格分隔），追加到默认排除表
#
# 用法（服务器上）：
#   bash -c "$(curl -sSL https://raw.githubusercontent.com/xujun105-cell/ai-seo-website/ops/deploy/deploy_aliyun.sh)"
set -euo pipefail

REPO="${XLD_REPO:-https://github.com/xujun105-cell/ai-seo-website.git}"
BASE="${XLD_BASE:-}"
DOMAIN="${XLD_HOST:-aiqiangban.com}"
BASE_EXPLICIT=0
[ -n "$BASE" ] && BASE_EXPLICIT=1
TS="$(date +%Y%m%d-%H%M%S)"
REL="$BASE/releases/$TS"
PUB="$BASE/releases/$TS.publish"
SKIP_SYSTEM="${XLD_SKIP_SYSTEM:-0}"

log(){ echo "[deploy] $*"; }
fail(){ echo "[deploy][FAIL] $*"; exit 1; }

# 默认排除：git 元数据 + agent 工作区文件（这些不该出现在站点根目录）
# 注意：indexnow-key.txt 不在排除表 —— IndexNow 协议要求 key 能在域名根路径被抓取，属刻意公开
DEFAULT_EXCLUDE=".git .git .gitignore .openclaw AGENTS.md MEMORY.md USER.md SOUL.md IDENTITY.md TOOLS.md HEARTBEAT.md _internal deploy memory"

# ---------- 0. 部署前勘察（不改任何东西）----------
log "=== 0/7 现场勘察 ==="

# 0.1 自动探测 nginx 的实际站点根 —— 防止"部署成功但没生效"（root 指向别处）
detect_root(){
  command -v nginx >/dev/null 2>&1 || return 1
  nginx -T 2>/dev/null > /tmp/xld_nginx_t.conf || return 1
  python3 - <<'PY' 2>/dev/null
import re,os
roots=[]
try: t=open("/tmp/xld_nginx_t.conf",encoding="utf-8",errors="ignore").read()
except Exception: raise SystemExit
for m in re.finditer(r'^\s*root\s+([^;]+);',t,re.M):
    r=m.group(1).strip().strip('"')
    if r not in roots: roots.append(r)
# 打分：存在 + 有 index.html 的是最可能的站点根
def score(r):
    s=0
    if os.path.isdir(r): s+=10
    if os.path.exists(os.path.join(r,"index.html")): s+=100
    if os.path.exists(os.path.join(r,"sitemap.xml")): s+=50
    if r in ("/usr/share/nginx/html","/var/www/html","/var/www/html/enginx"): s-=1000
    return s
best=max(roots,key=score) if roots else ""
if best and score(best)>0:
    print(best)
PY
}
NGINX_ROOT="$(detect_root || true)"
if [ -n "$NGINX_ROOT" ]; then
  log "  nginx 探测到的站点根: $NGINX_ROOT"
else
  log "  nginx 站点根: 探测不到（nginx 未安装 / 无 root 指令 / 无 python3）"
fi

# 决定 BASE：显式指定优先；否则用探测值；都没有则用默认值
DEFAULT_BASE="/var/www/aiqiangban"
if [ "$BASE_EXPLICIT" = "1" ]; then
  if [ -n "$NGINX_ROOT" ] && [ "$NGINX_ROOT" != "$BASE" ]; then
    log "  ⚠️ 你指定的 XLD_BASE=$BASE 与 nginx 实际 root=$NGINX_ROOT 不一致"
    if [ "${XLD_ALLOW_ROOT_MISMATCH:-0}" != "1" ]; then
      fail "站点根不一致 —— 中止（否则会'部署成功但没生效'）。
       确认要用哪个就重跑：
         XLD_BASE=$NGINX_ROOT bash deploy_aliyun.sh
       或确认忽略：XLD_ALLOW_ROOT_MISMATCH=1 bash deploy_aliyun.sh"
    fi
    log "  (XLD_ALLOW_ROOT_MISMATCH=1，继续用 $BASE)"
  fi
elif [ -n "$NGINX_ROOT" ]; then
  BASE="$NGINX_ROOT"
  log "  采用探测到的站点根: $BASE"
else
  BASE="$DEFAULT_BASE"
  log "  采用默认站点根: $BASE"
fi

log "base 目录: $(ls -ld "$BASE" 2>/dev/null || echo '不存在')"
if [ -L "$BASE/current" ]; then
  log "current: 软链 → $(readlink "$BASE/current")"
elif [ -d "$BASE/current" ]; then
  log "current: 实目录（本次会迁移为软链，部署后回滚方式变为 ln -sfn）"
else
  log "current: 不存在（首次部署）"
fi
log "已有 releases: $(ls -1dt "$BASE"/releases/* 2>/dev/null | head -3 | tr '\n' ' ')"
log "git 版本: $(git --version 2>/dev/null || echo '缺失')"

# ---------- 1. 拉取 main ----------
log "=== 1/7 拉取 main ==="
mkdir -p "$BASE/releases"
CLONE="$BASE/releases/.clone-$TS"
git clone --depth 1 "$REPO" "$CLONE" || fail "clone 失败（网络或仓库不可达）"
log "  HEAD: $(cd "$CLONE" && git log --oneline -1)"

# ---------- 2. 导出干净站点（不含 .git / 内部文件）----------
log "=== 2/7 导出干净站点 ==="
rm -rf "$PUB"; mkdir -p "$PUB"
(cd "$CLONE" && git archive --format=tar HEAD) | tar -x -C "$PUB"
# 双保险：git archive 已不含 .git，这里再按排除表删一次（防 tar 行为差异）
# 排除表全是顶层名字，用 shell glob 逐个删 —— 不用 find -maxdepth（BSD find 不保证支持，会静默失效）
EX="$DEFAULT_EXCLUDE ${XLD_EXCLUDE:-}"
for pat in $EX; do
  for p in "$PUB"/$pat; do
    if [ -e "$p" ] || [ -L "$p" ]; then rm -rf "$p"; fi
  done
done
log "  已排除: $EX"
[ -e "$PUB/.git" ] && fail "站点目录仍含 .git —— 中止"
# 抽查：确认内部文件确实没进站点目录（静默失效会在这里暴露）
for probe_f in AGENTS.md MEMORY.md USER.md SOUL.md IDENTITY.md TOOLS.md HEARTBEAT.md .openclaw memory; do
  [ -e "$PUB/$probe_f" ] && fail "内部文件仍在站点目录: $probe_f —— 排除表失效，中止"
done
log "  ✅ 站点目录不含 .git 与内部工作区文件"
log "  站点文件数: $(find "$PUB" -type f | wc -l | tr -d ' ')"

# ---------- 3. 完整性校验 ----------
log "=== 3/7 完整性校验 ==="
for f in index.html sitemap.xml robots.txt; do
  [ -s "$PUB/$f" ] || fail "缺失 $f —— 中止，现网未动"
  log "  ✅ $f $(wc -c < "$PUB/$f") bytes"
done
# 仓库 sitemap 用 ns0: 命名空间前缀（<ns0:loc>），校验必须命名空间无关
grep -qE "<([a-zA-Z0-9]+:)?urlset" "$PUB/sitemap.xml" || fail "sitemap.xml 结构异常 —— 中止"
URLN=$(grep -oE "<([a-zA-Z0-9]+:)?loc>" "$PUB/sitemap.xml" | wc -l | tr -d ' ')
[ "$URLN" -gt 100 ] || fail "sitemap URL 数为 $URLN，异常偏少 —— 中止，现网未动"
log "  sitemap URL 数: $URLN"
KW=$(find "$PUB/keywords" -name "*.html" 2>/dev/null | wc -l | tr -d ' ')
log "  keywords 页数: ${KW:-0}"

# ---------- 3.5 生成 301 跳转表 ----------
# 两类问题页：
#   a) 39 个 keywords 合并桩（meta refresh 软跳，权重不传递）→ 改 nginx 301
#   b) 10 个 .html.html 双扩展（生成器 bug 产物，现网仍 200）→ 301 到去掉一层 .html 的规范 URL
# 生成 nginx snippet；服务器 root 若已指向本目录，301 立即生效
log "=== 3.5/7 生成 301 跳转表 ==="
# 注意：写到 $PUB（尚未 rename），因为 $REL 目录此时还不存在
REDMAP="$PUB/_redirects.conf"
python3 - "$PUB" "$REDMAP" <<'PY' 2>/dev/null || true
import re,os,sys,glob,urllib.parse
pub,out=sys.argv[1],sys.argv[2]
lines=["# 自动生成：keywords 合并桩 + 双扩展 URL 的 301 映射","# generated-by deploy_aliyun.sh"]
# a) 合并桩：读 meta refresh 的 url，规范化成相对路径
for f in sorted(glob.glob(os.path.join(pub,"keywords","*.html"))):
    h=open(f,encoding="utf-8",errors="ignore").read()
    m=re.search(r'url=([^"]+)',h)
    if 'http-equiv="refresh"' not in h or not m: continue
    tgt=urllib.parse.unquote(m.group(1)).split("aiqiangban.com",1)[-1].lstrip("/")
    src=os.path.relpath(f,pub)
    if not tgt or tgt==src: continue
    lines.append(f'rewrite ^/{re.escape(src)}$ /{tgt} permanent;')
# b) 双扩展：xxx.html.html → xxx.html
for f in sorted(glob.glob(os.path.join(pub,"keywords","*.html.html"))):
    src=os.path.relpath(f,pub)
    if src.endswith(".html.html"):
        tgt=src[:-5]  # 去掉一层 .html
        if os.path.exists(os.path.join(pub,tgt)):
            lines.append(f'rewrite ^/{re.escape(src)}$ /{tgt} permanent;')
open(out,"w",encoding="utf-8").write("\n".join(lines)+"\n")
PY
REDCNT=$(grep -c '^rewrite' "$REDMAP" 2>/dev/null || echo 0)
[ "$REDCNT" -gt 0 ] || fail "301 跳转表生成失败（0 条）—— 中止"
log "  301 条数: $REDCNT（合并桩 + 双扩展）"
log "  snippet: $REDMAP"

# ---------- 4. nginx root 预检（防"部署成功但没生效"）----------

# ---------- 3.6 凭据泄露守卫（发布目录里不能有凭据）----------
log "=== 3.6/7 凭据泄露守卫 ==="
LEAK=$(grep -rlE "token=[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|LTAI[A-Za-z0-9]{12,}|AKIA[A-Z0-9]{16}" "$PUB" 2>/dev/null | head -20 || true)
if [ -n "$LEAK" ]; then
  log "  [FAIL] 发布目录内检出疑似凭据 —— 中止，现网未动"
  echo "$LEAK" | sed "s/^/     /"
  fail "凭据泄露守卫命中，部署已中止"
fi
log "  OK 发布目录无凭据字面量"

log "=== 4/7 nginx root 预检 ==="
if command -v nginx >/dev/null 2>&1; then
  ALL_ROOTS=$(nginx -T 2>/dev/null | grep -oE "root[[:space:]]+[^;]+;" | sed 's/root[[:space:]]*//;s/;$//' | sort -u)
  log "  nginx root 取值:"; echo "$ALL_ROOTS" | sed 's/^/    /'
  if [ -n "$ALL_ROOTS" ]; then
    if echo "$ALL_ROOTS" | grep -qF "$BASE/current"; then
      log "  ✅ 存在指向 $BASE/current 的 root"
    elif echo "$ALL_ROOTS" | grep -qF "$BASE"; then
      log "  ⚠️ nginx root 指向 $BASE（不是 $BASE/current）"
      log "     软链切换后该 root 会自动跟随 current，无需改配置 ✅"
    else
      log "  ⚠️ 没有 root 指向 $BASE —— 本次部署可能不生效"
      log "     请把 nginx root 改到 $BASE/current 后 reload。"
    fi
  fi
else
  log "  nginx 未安装，跳过预检"
fi

# ---------- 5. 切换 current（软链，原子；旧版保留）----------
log "=== 5/7 切换 current ==="
PREV=""
if [ -L "$BASE/current" ]; then
  PREV="$(readlink "$BASE/current")"
elif [ -d "$BASE/current" ]; then
  PREV="$BASE/releases/legacy-dir-$TS"
  mv "$BASE/current" "$PREV"
  log "  旧实目录保留为 $PREV"
fi
# 发布目录定名后原子替换
mv "$PUB" "$REL"
# ln -sfn 的 -n 保证不会把链接建到"指向目录的软链"内部；不依赖 GNU 专有的 mv -T
ln -sfn "$REL" "$BASE/current"
log "  current → $(readlink "$BASE/current")"
[ -n "$PREV" ] && log "  回滚目标: $PREV"

# ---------- 6. nginx reload ----------
log "=== 6/7 nginx ==="
if [ "$SKIP_SYSTEM" = "1" ]; then
  log "  (DRY-RUN: 跳过 nginx reload)"
elif command -v nginx >/dev/null 2>&1; then
  # 若 snippet 目录可写，把 301 规则装上（nginx.d 优先）
  SNIPDIR=""
  for d in /etc/nginx/conf.d /etc/nginx/snippets /usr/local/nginx/conf; do
    if [ -d "$d" ] && [ -w "$d" ]; then SNIPDIR="$d"; break; fi
  done
  if [ -n "$SNIPDIR" ] && [ -f "$REL/_redirects.conf" ]; then
    cp "$REL/_redirects.conf" "$SNIPDIR/aiqiangban-redirects.conf" 2>/dev/null && \
      log "  已安装 301 规则 → $SNIPDIR/aiqiangban-redirects.conf（需在 server{} 内 include）"
  fi
  nginx -t || { log "nginx 配置测试失败 —— 回滚"; [ -n "$PREV" ] && ln -sfn "$PREV" "$BASE/current"; exit 1; }
  systemctl reload nginx && log "  nginx reloaded"
else
  log "  nginx 未安装，跳过"
fi

# ---------- 7. 验收（字节级，不只看 200）----------
log "=== 7/7 验收 ==="
probe(){ curl -s -o /dev/null -w "%{http_code} %{size_download}B" -m 10 "$1" 2>/dev/null || echo "ERR"; }
# sha256sum（Linux）/ shasum（macOS）二选一
if command -v sha256sum >/dev/null 2>&1; then
  LOCAL_SHA=$(sha256sum "$REL/index.html" 2>/dev/null | awk '{print $1}')
else
  LOCAL_SHA=$(shasum -a 256 "$REL/index.html" 2>/dev/null | awk '{print $1}')
fi
log "  本地 index.html sha256: ${LOCAL_SHA:0:16}…"
for path in / /sitemap.xml /robots.txt; do
  log "  127.0.0.1${path} → $(probe "http://127.0.0.1${path}")"
done
# 带域名 Host 验收：备案未完成时会被 ICP 网关 403，这是预期，不算部署失败
HOST_CODE=$(curl -s -o /tmp/xld_dom.html -w "%{http_code}" -m 12 -H "Host: $DOMAIN" "http://127.0.0.1/" 2>/dev/null || echo "ERR")
if [ "$HOST_CODE" = "403" ]; then
  log "  $DOMAIN → 403（ICP 未备案拦截，属预期；部署本身已完成）"
elif [ "$HOST_CODE" = "200" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    REM_SHA=$(sha256sum /tmp/xld_dom.html 2>/dev/null | awk '{print $1}')
  else
    REM_SHA=$(shasum -a 256 /tmp/xld_dom.html 2>/dev/null | awk '{print $1}')
  fi
  if [ -n "$LOCAL_SHA" ] && [ "$REM_SHA" != "$LOCAL_SHA" ]; then
    log "  $DOMAIN → 200 但内容与新版本不一致（远端 ${REM_SHA:0:16}… vs 本地 ${LOCAL_SHA:0:16}…）"
    log "     ⇒ nginx 很可能还在服务旧 root，检查第 0/4 步的 root 探测输出"
    log "  [FAIL] 部署未生效"
    exit 1
  else
    log "  $DOMAIN → 200 且内容与新版本一致 ✅"
  fi
else
  log "  $DOMAIN → $HOST_CODE（注意：非 403 说明已过 ICP，排查返回内容）"
fi
# .git 暴露自检：现网曾公开 /.git/config（可拉全历史），部署后必须不再暴露
GITC=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "http://127.0.0.1/.git/config" 2>/dev/null || echo "ERR")
MEMC=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "http://127.0.0.1/MEMORY.md" 2>/dev/null || echo "ERR")
if [ "$MEMC" = "200" ]; then
  log "  🔴 /MEMORY.md 仍返回 200 —— 新发布目录仍含内部工作文档！"
  log "     处置：检查排除表（memory/ _internal/ 等）是否生效，并把 nginx root 指到 $BASE/current"
else
  log "  ✅ /MEMORY.md → $MEMC（新发布目录不含内部工作文档）"
fi
if [ "$GITC" = "200" ]; then
  log "  🔴 /.git/config 仍返回 200 —— 服务器仍在公开 git 目录！"
  log "     原因：nginx root 可能不指向 $BASE/current（指向了旧目录），或旧目录未清理。"
  log "     处置：把 nginx root 改到 $BASE/current 并 reload；或手动删除旧目录下的 .git"
else
  log "  ✅ /.git/config → $GITC（未暴露 git 目录）"
fi
# 关键页厚度（中文正文字数），验证"新内容真上线"而非"还是旧的薄壳"
if command -v python3 >/dev/null 2>&1; then
  CNT=$(python3 - "$REL" <<'PY' 2>/dev/null || echo "?"
import re,sys,glob,os
def cn(p):
    h=open(p,encoding='utf-8',errors='ignore').read()
    t=re.sub(r'<(script|style)[^>]*>.*?</\1>','',h,flags=re.S|re.I)
    t=re.sub(r'<[^>]+>',' ',t)
    return len(re.findall(r'[\u4e00-\u9fff]',t))
q=os.path.join(sys.argv[1],'qna','苏州墙板厂家哪家好.html')
print(cn(q) if os.path.exists(q) else '-')
PY
)
  log "  qna《苏州墙板厂家哪家好》中文字数 → ${CNT}（旧构建约 68，新构建约 1102）"
fi

log "=== 保留版本（可回滚）==="
ls -1dt "$BASE"/releases/* 2>/dev/null | head -5 | sed 's/^/  /'
log "回滚: ln -sfn <上面的目录> $BASE/current && systemctl reload nginx"
log "DONE ✅ 部署完成"
