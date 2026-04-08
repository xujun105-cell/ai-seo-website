# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for _your_ specifics — the stuff that's unique to your setup.

## What Goes Here

Things like:

- Camera names and locations
- SSH hosts and aliases
- Preferred voices for TTS
- Speaker/room names
- Device nicknames
- Anything environment-specific

## Examples

```markdown
### Cameras

- living-room → Main area, 180° wide angle
- front-door → Entrance, motion-triggered

### SSH

- home-server → 192.168.1.100, user: admin

### TTS

- Preferred voice: "Nova" (warm, slightly British)
- Default speaker: Kitchen HomePod
```

## Why Separate?

Skills are shared. Your setup is yours. Keeping them apart means you can update skills without losing your notes, and share skills without leaking your infrastructure.

---

## 百度搜索资源平台 API

- **Token**: `kZXcjDBmM3rBCuLp`
- **API地址**: `http://data.zz.baidu.com/urls?site=https://aiqiangban.com&token=kZXcjDBmM3rBCuLp`
- **提交方式**: `curl -H 'Content-Type: text/plain' --data-binary @urls.txt "http://data.zz.baidu.com/urls?site=https://aiqiangban.com&token=kZXcjDBmM3rBCuLp"`
- **每日配额**: 约10个URL（remain字段显示剩余配额）
- **位置**: 百度搜索资源平台 → 资源提交 → 普通收录 → API提交
- **注意**: Token从2026-04-06会话记录中找回，建议大哥在平台修改Token以防泄露

Add whatever helps you do your job. This is your cheat sheet.
