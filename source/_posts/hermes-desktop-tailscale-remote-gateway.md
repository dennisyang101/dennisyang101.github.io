---
title: 讓 MacBook 在外面也能用家裡的 Hermes Agent
date: 2026-07-13 19:42:37
categories:
  - 技術筆記
tags:
  - Hermes
  - Tailscale
  - macOS
  - 遠端連線
---

Hermes Agent 平常跑在家裡的 Mac Mini。那台機器不會帶出門，但它保留了我平常使用的環境：模型設定、工作檔案、terminal、skills 和 cron 都在那裡。

出門時我帶的是 MacBook。於是有一件事一直有點卡：明明 Mini 在家裡正常跑著，MacBook 卻只能算另一台乾淨的電腦。我要的不是再裝一套 Hermes，也不是把檔案複製到兩邊；我只想在外面打開 MacBook 的 Hermes Desktop，繼續操作家裡那個 Hermes。

這件事有兩個前提。第一，不能為了方便就開 router port，讓管理介面直接面對網際網路。第二，MacBook 只是入口，真正跑 agent 和處理檔案的地方仍然是 Mac Mini。

調研一輪後，我選 Tailscale。兩台 Mac 已經在同一個 Tailscale tailnet 裡，它提供一個加密的私有網路；MacBook 可以安全地找到 Mini，但外面的陌生裝置不會因此看到 Mini 的 Hermes 服務。

連線方向是 MacBook 找 Mini：MacBook 必須在同一個 tailnet 裡，而 Mini 的 Hermes 必須只聽自己的 Tailscale IP。如此一來，MacBook 找得到 Mini，Mini 也只會接受從這條私有網路進來的連線。

我原本以為這只是填一個遠端網址的事。最後倒也沒有變成很大的工程，不過中間改了兩次 Mac Mini 的設定，才搞懂每一層到底在做什麼。

## 一開始先連錯了服務

Mini 原本有一個 `hermes gateway` 在跑，它負責 Discord 和 cron 這類訊息通道。我先入為主地以為 Hermes Desktop 也是連它。

實際上不是。Desktop 的 **Remote gateway** 要連的是 `hermes serve`。

可以把兩者想成不同的門：`hermes gateway` 是 Hermes 收發外部訊息的門；`hermes serve` 才是讓 Desktop 打開介面、建立即時連線的門。名字很像，功能完全不同。

所以第一個調整，是在 Mini 上另外讓 `hermes serve` 常駐，並交給 launchd 管理。到這裡，MacBook 至少有一個正確的目標可以連。

接著我開始處理 Tailscale Serve。它是 Tailscale 提供的反向代理功能，可以理解成一個接待台：MacBook 先連到這個 HTTPS 入口，接待台再把請求轉交給後面的 `hermes serve`。我當時想藉它提供一個看起來較標準的 HTTPS 網址。

```text
MacBook 的 Hermes Desktop
  → Tailscale Serve
  → Mac Mini 上的 hermes serve
```

看起來比直接開服務更完整，也有 HTTPS；但第一個問題就是從這裡開始的。

## 第一次卡住：看起來都通，Hermes 卻沒回話

MacBook 端當時其實有不少好消息：Tailscale 顯示 Mini 在線、443 port 有反應，TLS handshake 也成功。照這些訊號看，像是已經連上了。

但真正用 Desktop 打開服務時，它一直等不到 Hermes 的回應。入口有亮，後面卻沒有人開門。

後來回頭看設定，才發現我把路繞複雜了。Tailscale Serve 已經把請求帶到 Mac Mini，卻又被設定成轉送到 Mini 自己的 Tailscale 位址。等於訪客已經走到門口，又被請去繞社區一圈，再回到同一扇門。這條繞路在我的設定裡沒有成功，Hermes 因此根本沒有收到請求。

![移除 Tailscale Serve 前後的連線路徑](/images/hermes-tailscale-serve-removal.svg)

我先把轉送目標改成 `127.0.0.1:9119`，也就是 Mini 自己的本機位址。這次終於拿到 HTTP 回應，證明請求有進到 Hermes；下一個錯誤隨即出現。

這一段學到的是：看到網路通了，不代表功能真的可用。還是得確認最末端的服務有收到請求、有回應。

## 第二次卡住：請求終於到了，主機端卻拒絕它

第一個問題確認後，我先停止讓 Tailscale Serve 把請求送回 Mini 自己的 Tailscale 位址，改交給 Mini 的本機服務。這次 HTTP 終於有回應：請求確實進了 Mac Mini，也找到了 Hermes。

不過 Hermes 馬上回了：

```text
Invalid Host header
```

白話來說，路走對了，主機端卻不認得這個來訪者。

原因是 Hermes 當時只待在 Mini 的本機位址 `127.0.0.1`。它只預期收到「Mini 自己」的地址；但 Tailscale Serve 轉送過來的請求，帶的是外部的 Tailscale 網址名稱。Hermes 看到兩個地址不一致，就把門關上。

這個檢查不能直接拿掉。它是安全保護：原本只打算給本機使用的服務，不應該因為有人換了一個網址名稱，就接受任何來源的請求。

看似簡單的做法是直接把服務改成接受整個家用 LAN 的連線，或略過這個檢查。雖然錯誤可能會消失，但管理入口也會開得比需求更大。既然 Tailscale 已經提供一條可由 tailnet 規則控管的私有路徑，比較好的解法是讓 Hermes 直接待在那條路上。

## 第二次調整：讓 MacBook 直接走 Tailscale 到 Mini

既然 MacBook 和 Mini 已經在同一個私有網路，Tailscale Serve 其實不是必要的中間人。

最後做法是：Mini 上的 `hermes serve` 只綁定自己的 Tailscale IP，MacBook Desktop 也直接連那個 IP。

```text
MacBook 的 Hermes Desktop
  → Tailscale 加密私有網路
  → Mac Mini 的 hermes serve
```

概念上的設定只有兩件事：

```text
Mac Mini：hermes serve --host <TAILSCALE_IP> --port 9119 --no-open
MacBook：Remote gateway = http://<TAILSCALE_IP>:9119
```

原本與最後的差別是：

```text
原本：Hermes 只認得「Mini 自己」的本機地址
      MacBook 經 Serve 帶來「另一個外部地址」
      → Hermes 拒絕

最後：Hermes 聽在 Mini 的 Tailscale 地址
      MacBook 也連 Mini 的 Tailscale 地址
      → 地址一致，Hermes 接受
```

這次路徑短了，也剛好解掉前面兩個問題：

- 請求不再經過多餘的接待台，不會繞回 Mini 自己。
- Desktop 使用的網址和 Mini 服務監聽的網址一致，Hermes 不會再把它誤認成不該接受的請求。

網址雖然寫成 `http://`，但資料不是直接經過公網傳送；它仍在 Tailscale 的私有連線中。這個情境下，再多加一層反向代理和 TLS，沒有解決實際問題，反而多了一個可能壞掉的地方。

## 這樣直接連，安全嗎？

前提是兩台裝置都已加入同一個 Tailscale tailnet，而且 tailnet 的存取規則只允許應該連線的裝置。這條路徑沒有 router port forwarding，也不把 `hermes serve` 綁到 `0.0.0.0`；它只聽 Mini 的 Tailscale IP。因此家用 LAN 上其他裝置和公網使用者都不會看到這個服務。

傳輸層由 Tailscale 的 WireGuard 加密，Hermes 本身則保留 Basic Auth。前者保護 MacBook 到 Mini 的網路路徑，後者保護實際進入 Hermes 的人，因此 Desktop 仍會顯示帳密登入表單。這也是我沒有為了排錯關掉登入，或改成對整個 LAN 開放服務的原因。

## 最後怎麼知道它真的好了

最後的驗證不是只看 ping 通，而是拿 MacBook 實際走完一次使用流程：

1. Hermes Desktop 找得到 Mini，並顯示登入表單。
2. 輸入帳密後可以儲存設定並重新連線。
3. Desktop 顯示已連上，也能正常操作 Mini 上的 Hermes。

技術上，最後的即時連線完成了 WebSocket upgrade，收到了 `101 Switching Protocols` 和 `gateway.ready`。這代表整條路真的接通；一般使用時，只要 Desktop 能正常連上並工作就夠了。

最後留下來的東西比一開始想像的少：Tailscale、只綁 Tailscale IP 的 `hermes serve`，以及登入保護。沒有 port forwarding，沒有公開的管理介面，也沒有不必要的反向代理。

這次比較有意思的不是某個指令，而是過程裡一直在做同一件事：每多一層設定，就多一個可能出錯的位置。既然兩台 Mac 已經在同一個安全的私有網路裡，直接連反而是最穩、也最容易維護的方案。

<details>
<summary>技術備註：第二次錯誤的原因</summary>

`hermes serve` 綁在 `127.0.0.1` 時，只接受 `localhost` 或 `127.0.0.1` 這類本機 Host header。Tailscale Serve 轉送時保留外部的 Tailscale hostname，因此觸發 Hermes 的 Host header／DNS rebinding 防護。

</details>
