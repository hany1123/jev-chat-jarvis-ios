# Jev Jarvis → TrollStore IPA 打包指南

面向场景：iPhone **iOS 16.3**（已越狱 / 已装 TrollStore），要把
[jev-chat/jev-chat-jarvis-ios](https://github.com/jev-chat/jev-chat-jarvis-ios)
这个键盘扩展装到自己手机上。

---

## 结论先说

| 项目 | 结论 |
|---|---|
| 能否打包成 IPA | ✅ 能，无第三方依赖，纯原生 Swift/UIKit |
| 能否用 TrollStore 装到 iOS 16.3 | ✅ 能，TrollStore 2 支持 iOS 15.5–16.6.1 |
| 键盘扩展（appex）能否正常挂载 | ✅ 能，`Embed Foundation Extensions` 阶段已配好 |
| App Group 配置共享是否可用 | ✅ 能，ldid 伪签名会保留 entitlement |
| 需要 Mac 吗 | ⚠️ 需要（有 Mac 本地编译）或用 GitHub Actions 云编译（**推荐，Windows 也能做**） |
| 需要付费开发者账号吗 | ❌ 不需要 |

**为什么 iOS 16.3 没问题：**
- 项目 `IPHONEOS_DEPLOYMENT_TARGET = 16.0`，16.3 ≥ 16.0，向上兼容
- TrollStore 2 的 CoreTrust 漏洞覆盖 iOS 15.5–16.6.1，16.3 落在区间内
- 代码里没有用到 iOS 17+ 独占 API（`NavigationStack` 是 iOS 16 引入的，可用）

---

## 打包原理

TrollStore 安装 IPA 时会用自己的伪根证书**重签**二进制，但会**保留**你在
打包阶段用 ldid 写进去的 entitlements。所以流程是：

```
Mac 编译 → 得到 JevJarvis.app（未签名）
        → ldid -S 伪签主程序 + 键盘扩展
        → 打成 Payload/ 结构 → 压成 .ipa
        → TrollStore 打开安装 → 永久签名
```

两个必须做对的点：

1. **主程序和 appex 都要伪签名**
   只签主程序，键盘扩展会因签名无效而加载失败（表现：设置里根本没有「Jev 键盘」）。
2. **entitlements 里必须带 App Group**
   `group.com.jevchat.jarvis` 是主 App 与键盘扩展共享配置的通道
   （`Shared/JevModel.swift:126`）。没有它，扩展读不到配置，功能等于瘫。

---

## 方案 A：GitHub Actions 云编译（Windows 也能做，推荐）

本仓库已带好工作流：`.github/workflows/build-trollstore-ipa.yml`

### 步骤

1. **Fork 仓库**到你的 GitHub 账号
   （MIT 协议，Fork 无需申请）

2. **打开 Actions 页签**，左侧选 `Build TrollStore IPA`

3. 点 **Run workflow**，`configuration` 选 `Release`，点绿箭头

4. 等约 8–15 分钟（macOS runner 排队 + 编译）

5. 绿色勾 ✅ 后，在运行详情页底部 **Artifacts** 下载
   `JevJarvis-trollstore-ipa`，解压得到：
   - `JevJarvis-trollstore.ipa` — 装这个
   - `SHA256SUMS.txt` — 校验用

6. 把 IPA 传到 iPhone（AirDrop / 微信文件传输助手 / iCloud 均可）

7. iPhone 上用 **TrollStore** 打开该 IPA → 安装

### 工作流已自动处理 Xcode 版本差异

README 写「本工程用 Xcode 27 验证编译」，但 runner 镜像自带的是 Xcode 16.x。
我已确认代码里**没有** iOS 17+/26 专属 API（Swift 5 模式、deployment target 16.0、
无 `glassEffect`/`ContentUnavailableView`/`@Observable` 等），旧版 Xcode 同样能编过。

所以工作流不固定单一版本，而是**遍历 runner 上所有已安装的 Xcode**，
用 `xcode-select` 逐个切换，编译成功即停。全失败才报错。
这样不管镜像带的是哪个版本都能出包。

### 为什么工作流里清空了 DEVELOPMENT_TEAM

`project.yml` 和 `project.pbxproj` 里硬编码了作者的团队 ID `75LZ93U5CF`。
在 CI 上没有该账号的证书，保留它会导致签名失败。所以工作流显式传：

```
CODE_SIGNING_ALLOWED=NO
CODE_SIGNING_REQUIRED=NO
CODE_SIGN_IDENTITY=""
DEVELOPMENT_TEAM=""
PROVISIONING_PROFILE_SPECIFIER=""
```

编译产出未签名二进制，交给 ldid 伪签名处理。

---

## 方案 B：本地 Mac 编译

```bash
# 1. 装依赖
brew install ldid xcodegen

# 2. 拉代码
git clone https://github.com/jev-chat/jev-chat-jarvis-ios.git
cd jev-chat-jarvis-ios

# 3. 编译（未签名）
xcodegen generate    # 如果用仓库自带的 .xcodeproj 可跳过这步
xcodebuild \
  -project JevJarvis.xcodeproj \
  -scheme JevJarvis \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  build

# 4. 伪签名 + 打包
bash scripts/build_trollstore_ipa.sh

# 5. 产物
# out/JevJarvis-trollstore.ipa
```

脚本会自动：
- 定位编译产物（先找 `build/`，再扫 DerivedData）
- 组装 `Payload/JevJarvis.app`
- 检查 `PlugIns/JevKeyboard.appex` 是否嵌入（缺失则从 Products 目录兜底补入）
- 分别对 `JevJarvis` 和 `JevKeyboard` 两个二进制做 ldid 伪签名
- 压成 IPA 并打印结构 + entitlement 自检

> `xcodegen generate` 会用 `project.yml` 重新生成 `.xcodeproj`。
> 仓库里已经带了生成好的 `.xcodeproj`，不改工程定义的话这步可以跳过。

---

## 方案 C：命令行一条龙（本地 Mac）

不想开 Xcode的话，用 `gh` 直接触发云端工作流并下载产物：

```bash
gh workflow run build-trollstore-ipa.yml -f configuration=Release
gh run watch          # 等它跑完
gh run download       # 产物落到当前目录
```

---

## 方案 D：iOS 设备已越狱，直接装（不走 TrollStore）

如果你的 16.3 设备已经越狱，其实**不需要 TrollStore**：

1. 用方案 A/B 拿到 IPA
2. 在 Mac 上用 `ldid` 伪签（`scripts/build_trollstore_ipa.sh` 已经做了）
3. 通过 **AppSync** / **Sileo** / **Filza** 安装，或用
   `ideviceinstaller` 配合已越狱设备安装

这条路的好处：没有 TrollStore 的 CoreTrust 版本限制，也不怕
「图标缓存重载后 App 消失」的问题。TrollStore 用户反而需要额外装
Persistence Helper 来解决这一问题。

## 装好之后必做的配置

装上 ≠ 能用。键盘扩展的联网和共享容器**都依赖「允许完全访问」**。

1. **设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → Jev 键盘**
2. 点进「Jev 键盘」→ 打开 **允许完全访问** → 弹窗点「允许」
   （必须开，否则：读不了剪贴板、不能联网、读不到 App Group 配置）
3. 打开 **Jev Jarvis** App：
   - 「开始」页确认自检项全绿
   - 「模型」页填入 API（Base URL / Key / 模型名）
   - 点「测试连接」验证
   - 「话术」页挑要用的模板
4. 回到任意聊天 App，长按地球键切到「Jev 键盘」→ 复制一条消息 → 点「分析剪贴板」

---

## 常见问题

### 装上了但设置里没有「Jev 键盘」

键盘扩展没挂载成功。检查：

```bash
unzip -l out/JevJarvis-trollstore.ipa | grep PlugIns
```

必须能看到 `Payload/JevJarvis.app/PlugIns/JevKeyboard.appex/`。
没有的话说明 Embed 阶段没跑，脚本的兜底分支会从 Products 目录补入——
若仍失败，检查 `JevJarvis.xcodeproj` 的 Embed Foundation Extensions 阶段。

### 键盘显示「需要完全访问」

没开「允许完全访问」，或者刚装完还没重启扩展。开关在
设置 → 通用 → 键盘 → 键盘 → Jev 键盘。

### App 里显示 App Group 不可写

`App/Sources/SetupView.swift:28` 有 `groupWritable` 自检。失败说明
entitlement 没带上——重新用 `scripts/trollstore.entitlements` 伪签，
且**两个二进制都要签**。源码里 `UserDefaults(suiteName:)` 有 `?? .standard`
兜底，签名不对时不会崩，但配置会不共享。

### IPA 打开提示「无法安装」

- 确认 iOS 版本：TrollStore 只支持 15.5–16.6.1 / 17.0，16.3 没问题
- 确认 IPA 没损坏
- TrollStore 需 2.0.7 及以上（早期版本有「所有 App 共用一个数据容器」的 bug）

### 装完重启后 App 消失 / 打不开

TrollStore 的已知问题：图标缓存重载后 App 会退回 User 状态。
解决：TrollStore → 设置 → **Install Persistence Helper** → 选一个系统 App
（比如「提示」Tips）。装完重启即可。

---

## 涉及的文件

| 文件 | 作用 |
|---|---|
| `.github/workflows/build-trollstore-ipa.yml` | CI 云编译工作流 |
| `scripts/build_trollstore_ipa.sh` | 伪签名 + 打包脚本 |
| `scripts/trollstore.entitlements` | 伪签名用的 entitlements（App Group） |
| `docs/TROLLSTORE_GUIDE.md` | 本文档 |
