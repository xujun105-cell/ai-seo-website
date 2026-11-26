#!/usr/bin/env python3
# patch_nginx_tls.py
# 给已存在的 server 块补 listen 443 ssl + 证书链; 没有匹配 server 块时用 fallback 新建一个
# 先备份并写备份清单 (供回滚); 只改含目标域名的 server 块; 已有 443 或 ssl_certificate 的跳过
# 端口按参数精确匹配 (8080 不算 80, 4433 不算 443); 跳过 .bak 备份文件
import argparse
import glob
import os
import shutil
import sys
import time


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--cert-name", default="aiqiangban.com")
    p.add_argument("--cert-dir", default="/etc/letsencrypt/live")
    p.add_argument("--dirs", nargs="*", default=["/etc/nginx/sites-enabled", "/etc/nginx/conf.d"])
    p.add_argument("--domain", default="aiqiangban.com")
    p.add_argument("--fallback-root", default="")
    p.add_argument("--fallback-conf", default="/etc/nginx/conf.d/aiqiangban-tls.conf")
    p.add_argument("--work", default="/tmp/xld_tls_patch")
    return p.parse_args()


def strip_comment(line):
    idx = line.find("#")
    if idx >= 0:
        return line[:idx]
    return line


def listen_ports(code):
    ports = set()
    for stmt in code.split(";"):
        s = stmt.split("{")[-1].strip()
        if not s.startswith("listen"):
            continue
        for tok in s.split()[1:]:
            tok = tok.strip()
            if tok.startswith("["):
                tok = tok.split("]", 1)[-1].lstrip(":")
            if not tok or not tok.isdigit():
                continue
            ports.add(tok)
    return ports


def has_port(code, port):
    return port in listen_ports(code)


def top_level_blocks(lines):
    depth = 0
    start = None
    out = []
    for i, line in enumerate(lines):
        code = strip_comment(line)
        opens = code.count("{")
        closes = code.count("}")
        if depth == 0:
            if opens > 0:
                start = i
                depth = opens - closes
                if depth <= 0:
                    out.append((start, i))
                    start = None
                    depth = 0
            continue
        depth += opens - closes
        if depth <= 0:
            out.append((start, i))
            start = None
            depth = 0
    return out


def main():
    a = parse_args()
    cert_dir = os.path.join(a.cert_dir, a.cert_name)
    fullchain = os.path.join(cert_dir, "fullchain.pem")
    privkey = os.path.join(cert_dir, "privkey.pem")
    if not (os.path.isfile(fullchain) and os.path.isfile(privkey)):
        print("SKIP: 证书文件不存在 " + fullchain)
        return 2
    os.makedirs(a.work, exist_ok=True)
    manifest = os.path.join(a.work, "backup_manifest.txt")
    files = []
    for d in a.dirs:
        for pat in ("*.conf", "*.default", "*"):
            files.extend(glob.glob(os.path.join(d, pat)))
    files = sorted(set(f for f in files if os.path.isfile(f) and ".bak." not in f))
    patched = []
    backups = []
    stamp = time.strftime("%Y%m%d-%H%M%S")
    for f in files:
        try:
            with open(f, encoding="utf-8", errors="ignore") as fh:
                text = fh.read()
        except Exception as exc:
            print("SKIP: 无法读取 " + f + " " + str(exc))
            continue
        if a.domain not in text:
            continue
        lines = text.splitlines()
        changed = False
        for (s, e) in reversed(top_level_blocks(lines)):
            header = lines[s]
            body = "\n".join(lines[s:e + 1])
            if not header.strip().startswith("server"):
                continue
            if a.domain not in body:
                continue
            if "ssl_certificate" in body:
                continue
            if has_port(body, "443"):
                continue
            if not has_port(body, "80"):
                continue
            for idx in range(s, e + 1):
                code = strip_comment(lines[idx])
                if has_port(code, "80"):
                    indent = lines[idx][:len(lines[idx]) - len(lines[idx].lstrip())]
                    insert = [
                        indent + "listen 443 ssl;",
                        indent + "listen [::]:443 ssl;",
                        indent + "ssl_certificate " + fullchain + ";",
                        indent + "ssl_certificate_key " + privkey + ";",
                        indent + "ssl_protocols TLSv1.2 TLSv1.3;",
                        indent + "ssl_session_cache shared:SSL:10m;",
                        indent + "ssl_session_timeout 1d;",
                    ]
                    lines[idx + 1:idx + 1] = insert
                    changed = True
                    print("PATCH: " + f + " 行 " + str(idx + 1) + " 之后插入 443 配置")
                    break
        if changed:
            bak = f + ".bak." + stamp
            shutil.copy2(f, bak)
            backups.append(f + "|" + bak)
            with open(f, "w", encoding="utf-8") as fh:
                fh.write("\n".join(lines) + "\n")
            patched.append(f)
    if not patched and a.fallback_root:
        os.makedirs(os.path.dirname(a.fallback_conf), exist_ok=True)
        conf = [
            "server {",
            "    listen 80;",
            "    listen [::]:80;",
            "    listen 443 ssl;",
            "    listen [::]:443 ssl;",
            "    server_name " + a.domain + " www." + a.domain + ";",
            "    ssl_certificate " + fullchain + ";",
            "    ssl_certificate_key " + privkey + ";",
            "    ssl_protocols TLSv1.2 TLSv1.3;",
            "    root " + a.fallback_root + ";",
            "    index index.html;",
            "    location / {",
            "        try_files $uri $uri/ =404;",
            "    }",
            "}",
        ]
        with open(a.fallback_conf, "w", encoding="utf-8") as fh:
            fh.write("\n".join(conf) + "\n")
        patched.append(a.fallback_conf)
        print("FALLBACK: 未找到含域名的 server 块, 已新建 " + a.fallback_conf)
    with open(manifest, "a", encoding="utf-8") as fh:
        for b in backups:
            fh.write(b + "\n")
    print("已改文件数: " + str(len(patched)))
    print("备份清单: " + manifest)
    if not patched:
        print("WARN: 没有可补的 server 块")
    return 0


sys.exit(main())

