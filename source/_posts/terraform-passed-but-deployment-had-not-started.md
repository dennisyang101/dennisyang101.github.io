---
title: Terraform 通過之後，部署其實才剛開始
date: 2026-07-18 22:21:55
categories:
  - 技術筆記
tags:
  - AWS
  - Terraform
  - GitHub Actions
  - OIDC
  - Palworld
description: 第一次把 Palworld 伺服器部署到 AWS。Terraform 驗證都通過後，真正出問題的是 GitHub OIDC、CloudFormation 資源生命週期和 EventBridge Scheduler 之間的交界。
---

這次想在 AWS 放一台 Palworld 專用伺服器。需求沒有很複雜：GitHub Actions 負責建立或更新基礎設施，EC2 跑 Docker，世界存檔放在獨立磁碟。平常不開 SSH，改用 AWS Systems Manager 管理；修改設定後，也希望可以從 GitHub 再部署一次。

一開始看起來很順。Terraform 格式檢查和驗證都過了，CloudFormation template 也沒有問題，GitHub Actions 的 YAML 和 shell script 也各自驗證過。

但這些檢查只證明每一段「單獨看起來合理」。真正按下部署後，才發現接下來每一關都是不同系統在互相確認：GitHub 要證明自己是哪個 workflow，AWS 要決定要不要信它，CloudFormation 要維護資源，Scheduler 又要取得另一個角色的權限。

Terraform 通過後，部署其實才剛開始。

## 先把誰在信誰講清楚

這次的部署路徑大致是這樣：

```text
GitHub Actions
  → 用 OIDC 向 AWS STS 換短期權限
  → Terraform 建 EC2、EBS、網路與排程
  → 上傳部署檔到 S3
  → 用 SSM 對 EC2 下指令
  → EC2 拉官方容器 image，啟動 Palworld
```

這裡沒有把長期 AWS access key 放進 GitHub。每次 workflow 執行時，GitHub 會帶一張只給這次 job 使用的 OIDC token 去 AWS 換短期 credentials。

這幾個名詞很容易混在一起，我自己就是混過：

```text
GitHub 的 OIDC token
  = GitHub 說「這個 workflow 是我發的」的身分證

AWS 的 OIDC provider
  = AWS 用來驗證這張身分證的驗票機

CD role
  = 寫著「什麼身分可以部署」的門禁規則

短期 credentials
  = 通過門禁後，這一次 workflow 拿到的臨時通行證
```

CD role 是長期留下來的規則，每次 workflow 不會共用的是最後那張短期 credentials。下面三個問題，剛好各自壞在這條鏈的不同位置。

## 第一關：GitHub 明明拿到了 token，AWS 還是不讓它進來

CD role 的門禁規則會檢查 token 裡的 `sub` 欄位。它原本只接受指定 repository 的 `main` branch，大意像這樣：

```text
repo:<owner>/<repo>:ref:refs/heads/main
```

workflow 確實拿到了 JWT，但交給 AWS STS 換權限時被拒絕。意思是 GitHub 有出示身分證，CD role 看完後說「我不認這個格式」。

我原本先懷疑 IAM policy、OIDC provider 或 GitHub permissions。後來直接把 GitHub runner 拿到的 token claims 拉出來看，才找到差異。

舊規則預期的是 repository 名稱加 branch。GitHub 實際送來的 `sub` 則包含 owner 和 repository 的 immutable ID。它們仍然代表同一個 repository，但字串不一樣。門禁是精確比對，少一個字都不會過。

```text
CD role 期待：repo:<owner>/<repo>:ref:refs/heads/main
GitHub 實送：repo:<owner>@<owner-id>/<repo>@<repo-id>:ref:refs/heads/main
```

修法不是把規則放寬成「任何 GitHub token 都可以進」。bootstrap 先從 GitHub API 取回 repository 的 `sub_claim_prefix`，再組出只接受目標 branch 的條件。

修完後，用 GitHub runner 的真實 JWT 呼叫 `AssumeRoleWithWebIdentity` 成功。到這裡才證明 GitHub Actions 可以取得部署權限。範例 policy 能通過檢查，不代表它還符合 GitHub 目前實際送出的身分格式。

## 第二關：CD role 還在，但驗票機被刪掉了

OIDC 修好後，下一次更新卻出現另一個錯誤：

```text
InvalidIdentityToken
```

這次 token 格式已經正確，CD role 也不是換了一組。問題是 AWS 裡用來驗證 GitHub token 的 OIDC provider 不見了。

換回前面的比喻：門禁規則還在，但驗票機被拔掉了。GitHub 拿著正確身分證來，AWS 還是無法確認它是真的，因此回 `InvalidIdentityToken`。

問題出在 bootstrap template。當時想法很直覺：帳號裡如果已經有 GitHub OIDC provider，這次 CloudFormation 就不要再建立一個。於是我把 provider 放在 condition 後面，condition 是 false 時不建立。

第一次建立 stack 沒事，錯在後續更新。人看到 false，會理解成「已經有人管了，這次別碰」。CloudFormation 的理解不同：這個 stack 原本管理 provider，現在 template 說 condition 不成立，代表這個 resource 不該存在，因此要移除。

```text
第一次建立：condition = true
  → stack 建立 OIDC provider

下一次更新：condition = false
  → stack 從自己的資源清單移除 OIDC provider
  → GitHub token 沒有人能驗證
```

所以不是 CD role 沒有共用同一組。CD role 可以繼續存在，也會在每次 workflow 發新的短期 credentials；壞掉的是它信任鏈上的 OIDC provider。

最後做法很單純：同一個 bootstrap stack 建立的 OIDC provider，就讓同一個 stack 一直管理。不要把 condition 當成「略過管理」或資源認養機制。

## 第三關：Terraform 寫得過，但 IAM 條件放錯了時機

伺服器會保留定時開關機的能力，但預設關閉。開機比較單純；關機前則會先通知玩家、存檔、停止容器、備份世界資料，最後才關閉 EC2。

我希望 Scheduler 使用的 execution role 不會被別的資源濫用，所以在 Terraform 裡替 role trust policy 加了兩個限制：

- 請求必須來自同一個 AWS account。
- 請求來源必須是那一條指定 schedule 的 ARN。

這是合理的 confused-deputy 防護方向，AWS 文件也建議用 `aws:SourceAccount` 和 `aws:SourceArn` 限制跨服務代入角色。問題不在 Terraform 語法，而是我假設 schedule 在建立前就能拿自己的 ARN 證明身分。

但實際建立 schedule 時，AWS 回了：

```text
The execution role you provide must allow AWS EventBridge Scheduler to assume the role.
```

建立流程其實是這樣：

```text
Terraform 呼叫 CreateSchedule
  → Scheduler 先確認「我能不能 assume 這個 role？」
  → trust policy 回答「只有指定 schedule ARN 可以 assume」
  → 指定 schedule 此刻還不存在，無法滿足條件
  → CreateSchedule 失敗
```

這算是 IaC 設定寫錯。不過不是 Terraform 不能建立 Scheduler，而是 IAM policy 對建立時機的假設錯了。安全條件寫得比 AWS 當下能提供的資訊更細，結果反而誰都進不去。

最後保留 `SourceAccount`，移除那條在建立期無法成立的 schedule-specific `SourceArn`。這不是把防護整個拿掉，而是在實際流程下，留下真的能生效的限制。

## 最後，哪些東西是真的驗證過了？

修完這幾段後，GitHub Actions 確實能經由 OIDC 取得短期 AWS credentials；Terraform 能建立 EC2、獨立加密 EBS、SSM 管理權限和排程；部署流程也能把檔案交給 EC2，拉起官方 Palworld container。

容器啟動後，在 EC2 內確認它是 `Up`，遊戲使用的 UDP port 也有監聽。首次拉 image 和初始化花了幾分鐘，這也讓我順手調整了 SSM command 等待時間，不再把第一次部署當成普通設定更新。

但這篇不應該把它寫成「完整驗證」。我沒有再用真實遊戲客戶端建立角色並連入伺服器，所以遊戲層最後一段沒有測。確認的是 EC2、容器和 UDP socket 都正常，不是玩家已經完成一場遊戲。

部署完成後，這次也沒有保留資源或世界資料。teardown 時還多看到一個很實際的成本細節：EBS 上的 `prevent_destroy` 的確擋住了誤刪；而 CloudFormation 設成 retain 的版本化 S3 bucket，刪 stack 後也不會自動清掉所有 object versions 和 delete markers。要真的不再產生儲存費，這些殘留物還是要另外清。

## 我最後留下的規則

這次沒有得到什麼很新奇的架構。最後仍然是單台 EC2、Docker Compose、SSM、GitHub Actions 和 Terraform。

比較有用的收穫反而很樸素：

- `terraform validate` 驗證的是設定語法與 provider schema，不是跨服務部署一定成功。
- OIDC、CloudFormation、Scheduler 這種交界，不能只靠靜態檢查；要用真實 token、真實 stack update 和真實 API create 去驗證。
- 看到「條件」或「安全限制」時，要多問一句：它是在建立時、更新時，還是實際執行時成立？

把遊戲伺服器放上雲端，最後最花時間的不是遊戲本身，而是讓每個服務都能正確地相信下一個服務。這些邊界平常不太顯眼，等到真的部署時才會一起冒出來。

## 參考資料

- [GitHub Actions 的 OpenID Connect 說明](https://docs.github.com/en/actions/concepts/security/openid-connect)
- [AWS CloudFormation Conditions](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/intrinsic-function-reference-condition.html)
- [EventBridge Scheduler 的 confused deputy 防護](https://docs.aws.amazon.com/scheduler/latest/UserGuide/cross-service-confused-deputy-prevention.html)
