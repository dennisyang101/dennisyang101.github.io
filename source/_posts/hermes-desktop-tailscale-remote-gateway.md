---
title: 用 Tailscale 讓 MacBook Hermes Desktop 連回 Mac Mini
date: 2026-07-13 19:42:37
categories:
  - 技術筆記
tags:
  - Hermes
  - Tailscale
  - macOS
  - 遠端連線
---

我平常把 Hermes Agent 放在家裡的 Mac Mini。它負責跑 agent、開 terminal、讀寫工作檔案和執行排程；MacBook 則是出門時帶著的電腦。

我想做的事情其實很單純：人在外面時，打開 MacBook 的 Hermes Desktop，繼續使用家裡 Mini 上原本那個 Hermes。環境不用搬來搬去，工作也還是在 Mini 上完成。

我不想為了這件事開 router port，更不想把管理介面直接放到公網。查過可行方案後，選了 Tailscale。兩台 Mac 已經在同一個 Tailscale 私有網路裡，它能讓它們像在同一個安全的內網裡互相連線，而且傳輸會加密。

最後想要的路徑是：

```text
MacBook 的 Hermes Desktop
  → Tailscale 私有網路
  → 家裡 Mac Mini 上的 Hermes
```

中間實際調整了兩次 Mac Mini 的設定，才把這條路接通。

## 第一次調整：先找到 Desktop 真正要連的入口

Mini 原本已經有 `hermes gateway` 在跑。它負責 Discord、cron 這類訊息通道，我一開始以為 Desktop 也會連它。

後來才知道，Desktop 要連的是另一個入口：`hermes serve`。可以簡單理解成：前者讓 Hermes 收發訊息，後者讓 Desktop 打開並操作 Hermes。名字很像，但不是同一件事。

所以第一個改動，是讓 Mac Mini 另外常駐 `hermes serve`，交給 launchd 管理。這樣 MacBook 的 Desktop 才有一個明確的目的地可以連。

當時我多加了一層 Tailscale Serve，想讓 Desktop 連一個 HTTPS 網址。Tailscale Serve 有點像接待台：它先收到請求，再把請求交給後面的 Hermes。

```text
MacBook Desktop
  → Tailscale Serve
  → hermes serve
```

這個做法看起來合理，但第一次連線沒有真的成功。

## 問題一：入口看起來正常，Hermes 卻沒有收到請求

當時 MacBook 看到的狀態都不錯：Tailscale 顯示 Mini 在線、HTTPS 可以建立連線。照理說，應該快好了。

但實際打開服務時，畫面一直等不到 Hermes 的回應。

回頭看才發現，我把路繞複雜了。Tailscale Serve 已經把請求帶到 Mac Mini，卻又被設定成轉送到 Mini 自己的 Tailscale 位址。等於訪客已經到門口，又被請去繞社區一圈，再回到同一扇門。這段繞路沒有成功，Hermes 自然收不到請求。

![移除 Tailscale Serve 前後的連線路徑](/images/hermes-tailscale-serve-removal.svg)

我先把轉送目標改成 `127.0.0.1:9119`，也就是 Mini 自己的本機位址。這次 Hermes 終於有回應，證明請求真的進到了服務裡；不過它馬上又拒絕了請求。

這件事也提醒我，看到「網路通了」不代表整件事完成。連線入口正常，還要確認後面的 Hermes 真的有收到並回應。

## 問題二：Hermes 認不出這個請求

第二次出現的訊息是：

```text
Invalid Host header
```

白話來說，Hermes 原本被設定成只接受「這台 Mini 自己」的請求；但經過 Tailscale Serve 後，請求帶來的是另一個網址名稱。Hermes 認為這和它預期的來源不一致，所以拒絕了它。

這個限制不是多餘的麻煩，而是保護措施。把它關掉，或讓服務對整個家用 LAN 都開放，或許可以先讓錯誤消失；但也會把本來只想給 Tailscale 裝置用的管理入口放得太寬。我沒有採用這個做法。

<details>
<summary>技術上發生了什麼？</summary>

`hermes serve` 綁在 `127.0.0.1` 時，只接受 `localhost` 或 `127.0.0.1` 這類本機網址。Tailscale Serve 轉送時保留外部的 Tailscale hostname，因此觸發 Hermes 的 Host header／DNS rebinding 防護。

</details>

## 第二次調整：拿掉中間轉送，直接走 Tailscale

後來我把路徑縮短了。

既然 MacBook 和 Mini 已經在同一個 Tailscale 私有網路，就不需要再加 Tailscale Serve 當中間人。Mini 上的 `hermes serve` 直接只聽 Tailscale IP；MacBook Desktop 也直接連那個 IP。

```text
MacBook Desktop
  → Tailscale 加密連線
  → Mac Mini 的 hermes serve
```

設定概念上是這樣：

```text
hermes serve --host <TAILSCALE_IP> --port 9119 --no-open
MacBook Remote gateway: http://<TAILSCALE_IP>:9119
```

這樣做有三個原因：

- **少一層轉送。** 請求不用再經過 Serve，路徑更單純。
- **安全範圍剛好。** 服務只在 Tailscale 的私有網路出現，不會開到家用 LAN 或公網。
- **網址一致。** Desktop 連的位址和 Mini 服務聽的位址相同，Hermes 的保護機制不會再誤擋。

網址看起來是 `http://`，不過資料並不是直接裸露在網際網路上；兩台機器之間仍走 Tailscale 的 WireGuard 加密通道。這個情境下，再多加一層反向代理和 TLS 沒有帶來必要好處，反而多了出錯的位置。

## Tailscale 之外，還是要登入

即使只有同一個 Tailscale 網路裡的裝置能連進來，我仍保留 Hermes 的 Basic Auth。

Desktop 會顯示一般的帳密登入表單。登入後才建立與 Hermes 的即時連線。Tailscale 負責限制「哪些裝置可以靠近」，Basic Auth 則確認「正在操作的人是否能登入 Hermes」；兩層都保留。

## 最後怎麼確認真的好了

最後不是只看 ping 通，而是從 MacBook Desktop 真的走完一次使用流程：

1. Desktop 找得到 Mini，並顯示帳密登入。
2. 輸入帳密後可以儲存設定、重新連線。
3. Desktop 顯示已連上，能正常操作 Mini 上的 Hermes。

技術上，最後的即時連線完成了 WebSocket upgrade，收到 `101 Switching Protocols` 和 `gateway.ready`。這是我確認整條路真正打通的依據；一般使用時，只要 Desktop 可以正常連上並工作就夠了。

最後留下的設定其實不多：Tailscale、只綁 Tailscale IP 的 `hermes serve`，以及登入保護。沒有 port forwarding，也沒有公開的管理介面。對兩台已經在同一個 Tailscale 網路裡的 Mac，直接連反而是最穩、也最容易維護的方式。
