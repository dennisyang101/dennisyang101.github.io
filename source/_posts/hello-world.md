---
title: 用 Hexo 部署第一篇文章到 GitHub Pages
date: 2026-07-09 12:00:00
categories:
  - 技術筆記
tags:
  - Hexo
  - GitHub Pages
---

這篇記一下這個部落格怎麼從空資料夾變成 GitHub Pages。

## 1. 建 Hexo 專案

```bash
npx hexo-cli init dennisyang101.github.io
cd dennisyang101.github.io
npm install
```

## 2. 改基本設定

`_config.yml`：

```yaml
title: Dennis Yang
author: Dennis Yang
language: zh-TW
timezone: Asia/Taipei
url: https://dennisyang101.github.io
```

## 3. 寫第一篇文章

文章放在：

```text
source/_posts/hello-world.md
```

front matter 大概長這樣：

```yaml
---
title: 用 Hexo 部署第一篇文章到 GitHub Pages
date: 2026-07-09 12:00:00
categories:
  - 技術筆記
tags:
  - Hexo
  - GitHub Pages
---
```

## 4. 本機確認

```bash
npm run build
npm run server
```

打開 `http://localhost:4000` 看一下。沒問題再推。

## 5. 用 GitHub Actions 部署

這個 repo 用 `source` 分支放 Hexo 原始碼，GitHub Pages 由 Actions build。

workflow 放在：

```text
.github/workflows/pages.yml
```

之後只要：

```bash
git add .
git commit -m "Add first post"
git push
```

Actions 會自己跑 `npm ci`、`npm run build`，再把 `public/` 發到 GitHub Pages。
