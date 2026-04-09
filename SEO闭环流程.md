# SEO闭环流程

本流程定义SEO优化的完整闭环操作。

## 流程步骤

1. **生成内容** - 在 qna/ 目录生成新的问答文章（HTML格式）
2. **推送GitHub** - 提交新内容到GitHub仓库
3. **更新sitemap** - 将新URL追加到 sitemap.xml
4. **提交百度API** - 将新URL推送给百度搜索资源平台
5. **监控收录** - 检查百度对网站的收录情况
6. **分析结果** - 分析SEO数据（排名、收录量、流量）
7. **生成报告** - 汇总执行结果并发给大哥

## 内容规范

- Q&A文章放在 `qna/` 目录
- 文件名格式：`问题.html`（如：墙板多少钱一平方.html）
- 必须包含：`<title>`、`<meta name="description">`、`<link rel="canonical">`
- 每篇内容300字以上，包含联系方式

## 百度API提交

- API地址：`http://data.zz.baidu.com/urls?site=https://aiqiangban.com&token=kZXcjDBmM3rBCuLp`
- 每次最多提交10个URL
- 提交后记录返回值（success/remain字段）
