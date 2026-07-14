---
title: HTTP/3 為什麼跑在 UDP 上，卻還是可靠？
date: 2025-07-14 12:00:00
categories:
  - 技術筆記
tags:
  - 網路協議
  - UDP
  - QUIC
  - HTTP/3
description: HTTP/3 使用 UDP，不代表網頁傳輸放棄可靠性。可靠傳輸、加密與壅塞控制由 QUIC 處理，而 UDP 是它承載封包的方式。
---

以前剛學 TCP 和 UDP 時，很容易把它們記成二選一：TCP 可靠但慢，UDP 快但可能丟資料。

這個說法作為入門沒有錯，但放到現在的網路上已經不太夠用了。因為 HTTP/3 是建立在 QUIC 上，而 QUIC 的封包正是走 UDP。照舊印象來看，網頁怎麼會願意把 HTML、圖片和登入資料交給「可能丟包」的 UDP？

關鍵是：**HTTP/3 不是直接把網頁內容裸丟進 UDP。** UDP 只負責把 QUIC 封包送到另一端；可靠傳輸、排序、流量控制、壅塞控制和加密，則由 QUIC 自己處理。

## UDP 不可靠，QUIC 仍然可以可靠

UDP 本身很單純。它送出一個 datagram，沒有連線狀態，也不承諾對方一定收到、一定照原本順序收到。

QUIC 選擇用 UDP 當底層封包格式，但在上面補回網頁傳輸需要的能力：

```text
HTTP/3
  ↓
QUIC：stream、遺失偵測、重傳、壅塞控制、TLS 1.3
  ↓
UDP：把 QUIC 封包送到網路上
  ↓
IP
```

所以「HTTP/3 用 UDP」不等於「HTTP/3 不可靠」。比較接近的說法是：QUIC 不借用 TCP 已有的可靠傳輸機制，而是自己在 UDP 之上實作一套。

[IETF 的 QUIC 標準 RFC 9000](https://www.rfc-editor.org/rfc/rfc9000.html) 明確定義了遺失偵測、復原和壅塞控制所需的回饋機制；HTTP/3 則依賴 QUIC 提供每條 stream 內可靠且有順序的傳輸。[RFC 9114](https://www.rfc-editor.org/rfc/rfc9114.html) 也把這件事寫得很直接：HTTP/3 的可靠性是在 QUIC 的 stream 層，而不是 UDP 本身。

## 要解的不是「TCP 太慢」，而是一個封包拖住全部請求

HTTP/2 已經能讓多個請求共用一條 TCP 連線。瀏覽器可以同時請 HTML、CSS、JavaScript 和圖片，不必像 HTTP/1.1 那樣開很多 TCP 連線。

問題在於 TCP 只看得見一條按順序排列的位元組串流。假設其中一個 TCP 封包遺失，後面的資料即使已經到達，TCP 仍要先等遺失的部分補回來。這會讓同一條連線上的其他 HTTP/2 請求一起停住，稱為 transport-layer head-of-line blocking。

```text
HTTP/2 over TCP

CSS 的封包遺失
  ↓
TCP 等待重傳，維持整條位元組串流順序
  ↓
同一條連線上的圖片、JavaScript 回應也得等
```

這不是說 HTTP/2 沒有多工；它有。問題是 HTTP/2 的多工在 TCP 上面，但 TCP 不知道哪些位元組屬於哪個 HTTP 請求。

QUIC 把 stream 放到傳輸層。HTTP/3 的每個請求可以使用獨立的 QUIC stream；某條 stream 的封包遺失時，那條 stream 仍須等待重傳，但不必把其他 stream 一起卡住。

```text
HTTP/3 over QUIC over UDP

CSS 所在的 stream 有封包遺失
  ↓
QUIC 只重傳那條 stream 缺少的資料
  ↓
其他 stream 仍可繼續交付已收到的資料
```

這是 HTTP/3 選 QUIC 的主要理由之一。它不是讓丟包變得沒關係，而是把丟包造成的等待限制在受影響的 stream 裡。

## QUIC 不只是在 UDP 上加一個重傳

如果只是重傳，QUIC 不會值得另外做成一套傳輸協定。它還把幾件原本分散在 TCP、TLS 和 HTTP/2 的事情重新組合：

- **加密**：QUIC 整合 TLS 1.3。HTTP/3 不支援未加密的 QUIC 連線。
- **每條 stream 的流量控制**：一個慢的接收端不應無限吃掉記憶體，也不該輕易影響其他 stream。
- **整條連線的壅塞控制**：QUIC 仍然需要在網路塞車時降速，不能因為底層是 UDP 就任意送封包。
- **較快的重新連線條件**：對曾連過的伺服器，QUIC 可使用 0-RTT 提早送資料；但這不是每次新連線都免費加速，伺服器也必須考慮重送攻擊風險。
- **連線遷移**：裝置從 Wi‑Fi 切到行動網路時，QUIC 可以利用 connection ID 嘗試維持同一條連線；實際能否持續仍取決於雙方與網路狀況。

因此，把 QUIC 稱為「UDP 的替代品」不太準確。它比較像一個新的傳輸層協定，只是選擇把自己的封包放進 UDP datagram 裡，讓它能在既有網路設備上部署。

## 那 TCP 和 UDP 還怎麼選？

對應用程式開發者來說，選擇通常仍然很簡單：大多數需要可靠雙向連線的程式，用 TCP 或現有的 HTTPS stack 就好。瀏覽器是否改用 HTTP/3，主要是瀏覽器與伺服器協商的結果，不是網站前端要自己用 UDP socket 重寫。

UDP 適合的情境仍然存在，例如 DNS、即時語音、遊戲的位置更新，或應用本來就能容忍少量過期資料。這些場合常常寧可漏掉一個舊封包，也不要等待它重傳。

QUIC 則是另一種情況：它使用 UDP 的部署方式，但提供 HTTP 所需的可靠傳輸。它不能讓網路沒有遺失或延遲；它只是避免一個遺失封包把本來不相關的 HTTP 請求一起拖住。

下次看到瀏覽器顯示 HTTP/3 或 `h3` 時，可以把它想成這條路徑：UDP 在最底下送封包，QUIC 在中間負責可靠性與加密，HTTP/3 才在最上面傳遞網頁請求。

## 參考資料

- [RFC 9000: QUIC: A UDP-Based Multiplexed and Secure Transport](https://www.rfc-editor.org/rfc/rfc9000.html)
- [RFC 9114: HTTP/3](https://www.rfc-editor.org/rfc/rfc9114.html)
