---
title: Mac Mini 上讓 Agent 常駐：launchd 先處理生命週期
date: 2026-07-10 23:39:17
categories:
  - 技術筆記
tags:
  - macOS
  - launchd
  - AI Agent
  - Hermes
---

Agent 放在 Mac Mini 上跑，最容易先想到的是開一個 terminal，執行完再用 `nohup` 或 `&` 丟到背景。

這在第一次測試時沒問題，但不是常駐服務的做法。登入後有沒有啟動、程式掛掉要不要重拉、log 在哪裡，最後都會變成手動處理。

macOS 已經有做這件事的東西：`launchd`。

## 讓 launchd 管，不讓 shell 管

這台機器上的 Hermes gateway 是一個 LaunchAgent：

```text
~/Library/LaunchAgents/ai.hermes.gateway.plist
```

它的重點其實只有幾個：

```xml
<key>RunAtLoad</key>
<true/>
<key>KeepAlive</key>
<true/>

<key>StandardOutPath</key>
<string>/Users/neon/.hermes/logs/gateway.log</string>

<key>StandardErrorPath</key>
<string>/Users/neon/.hermes/logs/gateway.error.log</string>
```

`RunAtLoad` 處理登入後啟動，`KeepAlive` 處理非預期結束後重啟。stdout 和 stderr 不再散在某個 terminal 視窗，而是固定進 log。

這比自己寫一個永遠不會退出的 shell script 好，因為服務的生命週期交給作業系統，不是交給某次 SSH 連線或一個忘記關掉的 terminal。

## 不要假設環境跟互動式 shell 一樣

LaunchAgent 不會自動拿到我平常 terminal 裡的完整環境。因此 plist 要明確寫出執行檔、工作目錄和必要的環境變數。

目前 gateway 直接用 Hermes 自己的 venv 啟動：

```xml
<key>ProgramArguments</key>
<array>
  <string>/Users/neon/.hermes/hermes-agent/venv/bin/python</string>
  <string>-m</string>
  <string>hermes_cli.main</string>
  <string>gateway</string>
  <string>run</string>
  <string>--replace</string>
</array>

<key>WorkingDirectory</key>
<string>/Users/neon/.hermes</string>
```

不要在 plist 裡依賴 `.zshrc` 會不會被 source、`PATH` 有沒有剛好包含某個工具。常駐服務要用明確路徑；出了問題才有地方查。

## 檢查的是 launchd，不是只看 process

我平常用這兩個指令：

```bash
hermes gateway status
launchctl print gui/$(id -u)/ai.hermes.gateway
```

前者確認 Hermes 知道自己被 launchd 管理；後者能看出服務是否 `running`、PID、最後退出訊號，以及 stdout/stderr 的位置。

只看 `pgrep` 不夠。process 還在，不代表它下次登入或意外退出後能回來。

## 一個服務只留一個 owner

這次整理時也發現一個舊的 `com.hermes.gateway` LaunchAgent 還留在系統裡。它和現在的 `ai.hermes.gateway` 都試圖管理 gateway，舊 job 一直以 exit code 1 結束，`KeepAlive` 又不停把它拉起來。

這不是「多一層保險」，而是兩個 supervisor 在搶同一件事。常駐程式應該只有一個 owner：一份 plist、一個 label、一組 log。舊 job 要卸載，不要和新的服務並存。

## 目前的最低限度

對這台 Mac Mini 而言，這樣就夠了：

- gateway 由一個 LaunchAgent 管理
- plist 指向固定的 Python 與工作目錄
- `RunAtLoad` 和 `KeepAlive` 處理啟動與重啟
- log 路徑固定
- 用 `launchctl print` 檢查真實狀態

不用再加一個 process manager，也不用自己寫 watchdog。先讓系統原本的服務管理機制把該做的事情做好。
