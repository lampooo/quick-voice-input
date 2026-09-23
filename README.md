# 快捷语音输入

一个 Mac 菜单栏小工具：在任意输入框里**长按鼠标左键**（默认 0.5 秒）就开始用微信输入法语音输入，说完**松开鼠标**，文字上屏。

它自己不做语音识别。长按时，它替你按住微信输入法的「按住说话」快捷键；松开时，再替你松开。

## 工作原理

1. 左键按下后开始计时。0.5 秒内松开或移动超过约 5 pt，就当成普通点击或拖选，不做任何干预。
2. 时间到时，用「辅助功能」接口判断指针下是不是可编辑的输入框（密码框不触发）。
3. 是输入框的话，先补发一个 mouseUp，让应用结束「按住鼠标」状态；如果当前不是微信输入法就切过去；然后按住语音快捷键。
4. 说话期间，拖动鼠标会被改成普通移动，不会选中文字。
5. 松开鼠标时，这次 mouseUp 会被吞掉，同时松开快捷键，微信输入法识别整理后上屏。

另有两层保护：一是定时核对鼠标的真实状态，二是退出时一定松开按键，避免修饰键卡住。

## 系统要求

- macOS 13 或更新版本
- 微信输入法 Mac 版 2.2.1 或更新版本（2.2.1 起可以自定义语音快捷键；开发机上是 2.2.3）
- 自己编译需要 Xcode 16（Swift 5.9 及以上）

## 安装

```bash
git clone <仓库地址> quick-voice-input
cd quick-voice-input
./scripts/install.sh          # 编译、打包、签名并安装到 ~/Applications，不会自动启动
./scripts/install.sh --open   # 安装后立即打开
```

安装位置是 `~/Applications/快捷语音输入.app`。它是菜单栏应用，没有 Dock 图标。

签名方式：打包脚本会自动使用钥匙串里的「Apple Development」或「Developer ID」证书，这样以后重新打包也不用重新授权。找不到证书时退回 ad-hoc 签名，这种情况下每次重新安装都要重新授权。需要指定证书时，可以设置 `SIGN_IDENTITY="证书名称"`。

Bundle ID：「辅助功能」授权和设置都跟着 Bundle ID 走，所以打包时会沿用 `~/Applications` 里已安装版本的 Bundle ID；第一次安装时用 `com.quickvoiceinput.app`。需要指定时，可以设置 `BUNDLE_ID=你的.bundle.id`。

## 第一次使用

打开后会自动弹出设置向导，一共三件事：

1. **授权「辅助功能」**：点「去授权」，在「系统设置 → 隐私与安全性 → 辅助功能」里打开「快捷语音输入」。
2. **修改微信输入法的语音快捷键**：打开微信输入法设置 → 语音 → 「按住说话」，点快捷键框，按一下键盘**右侧的 Option（⌥）**。
3. **测试**：在向导里点「开始测试语音快捷键」，大约 20 秒跑完，会告诉你哪个键可用。然后在第 4 步的测试框里长按试一次。

### 为什么要改成右 Option

- macOS 不允许普通程序模拟 Fn 键，而 Fn 是微信输入法的默认语音键，所以必须换一个键。
- 右 Option 程序可以模拟，单独按它不会触发任何功能，Mac 自带键盘也有这个键，可以直接在微信输入法里录入。
- 单个修饰键不会产生字符，就算事件漏到应用里也不会误输入。

也可以选右 Command、右 Control 或 ⌥ + 空格，但要和微信输入法里的设置保持一致。右 Shift 会切换微信输入法的中英文，不建议使用。调研细节见 [docs/wetype-spike.md](docs/wetype-spike.md)。

## 日常使用

- 在输入框里按住左键不动，约 0.5 秒后开始说话，松开结束。用触控板时会轻震一下。
- 菜单栏图标：`mic` 表示待命，实心 `mic.fill` 表示正在听写，`mic.slash` 表示已暂停，三角感叹号表示缺少权限。
- 快速点击、双击、拖选、按住修饰键点击都和平时一样。

### 菜单

| 菜单项 | 作用 |
| --- | --- |
| 暂停 / 启用长按语音输入 | 临时关闭或恢复 |
| 辅助功能权限 | 显示授权状态；未授权时点它去授权 |
| 微信输入法 … 按住说话 = … | 读取微信输入法当前的快捷键，不一致时会提示 |
| 长按时长 | 0.3 / 0.5 / 0.8 / 1.2 秒 |
| 语音快捷键 | 选择要按住的键；里面有「测试语音快捷键…」，点一下自动跑完 |
| 触发前自动切到微信输入法 | 默认开启 |
| 在「当前应用」中 | 自动识别输入框 / 任意位置都触发 / 不触发 |
| 开机自动启动 | 使用系统的登录项 |
| 设置向导… / 打开日志文件夹 / 退出 | |

### 按应用规则

有些应用（部分 Electron 应用、网页编辑器、终端）的输入框通过「辅助功能」识别不出来。打开那个应用后，在菜单栏里把它设成「任意位置都触发」就行，这时在该应用里任意位置长按都会开始语音输入。终端类应用（Terminal、iTerm2、Warp、kitty、Ghostty 等）默认就是「任意位置都触发」。

## 常见问题

**测试显示「没有反应」**
先确认微信输入法里「按住说话」的快捷键和这里选的一致（菜单里会显示两边的设置）。再看测试结果底部有没有「安全输入」提示：密码框，或终端的「安全键盘输入」，会让所有键盘监听失效。

**授权了还是不工作**
在「辅助功能」列表里选中「快捷语音输入」，点「−」删除，再在向导里点「去授权」重新添加。用 ad-hoc 签名重新打包后必须这样做一次。

**某个应用里长按没反应**
把这个应用设成「任意位置都触发」。Chrome 和 Electron 应用第一次长按时才开启辅助功能树，可能需要再试一次。

**Option 键像是卡住了**
按一下右 Option 就能恢复。正常情况下，插件会在松开鼠标、退出或检测到异常时自动松开按键。

**终端里上屏异常**
有用户反馈微信输入法 2.2.3 在终端里语音上屏异常，这是输入法自身的问题。

**排查信息**
在终端运行下面的命令，可以打印权限、微信输入法、快捷键、麦克风和事件监听的状态（只读，不会按任何键）：

```bash
~/Applications/快捷语音输入.app/Contents/MacOS/QuickVoice --self-check
```

日志在 `~/Library/Logs/QuickVoiceInput/quickvoice.log`，只记录应用名、控件类型和耗时，不记录输入内容。

## 实测

测试清单见 [docs/test-checklist.md](docs/test-checklist.md)，覆盖备忘录、Safari、Chrome、微信、飞书 / VS Code 和终端。

## 开发

```bash
swift build              # 编译
swift test               # 运行 QuickVoiceCore 的单元测试
./scripts/build-app.sh   # 打包到 build/快捷语音输入.app（UNIVERSAL=1 同时编译 Intel 版）
.build/debug/QuickVoice --render-setup /tmp/setup   # 仅 Debug 构建：离屏渲染设置向导截图，不显示窗口
```

| 路径 | 内容 |
| --- | --- |
| `Sources/QuickVoiceCore/` | 纯逻辑，可以单测：长按状态机、快捷键和按键序列、MMKV 读取、微信输入法配置解析、按应用规则 |
| `Sources/QuickVoice/EventTap.swift` | 独立线程上的 CGEventTap，只监听左键，负责吞掉或改写事件 |
| `Sources/QuickVoice/TextFieldProbe.swift` | 用「辅助功能」识别输入框，为 Chromium / Electron 开启 `AXManualAccessibility` |
| `Sources/QuickVoice/KeySynth.swift` | 在 HID 层合成按键；修饰键用 flagsChanged，并带上区分左右的设备位 |
| `Sources/QuickVoice/VoiceController.swift` | 切输入法、按住和松开快捷键、防卡键看门狗 |
| `Sources/QuickVoice/HotkeyDiagnostics.swift` | 「测试语音快捷键」 |
| `Sources/QuickVoice/MenuBar.swift`、`Settings.swift`、`Onboarding.swift` | 菜单、设置、设置向导 |
| `scripts/` | 打包、签名、安装和图标生成 |

## 卸载

1. 在菜单里退出「快捷语音输入」。
2. 可选：清除设置和日志。要在删除 App 之前做，因为命令会从 App 里读出 Bundle ID：

   ```bash
   defaults delete "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' ~/Applications/快捷语音输入.app/Contents/Info.plist)"
   rm -rf ~/Library/Logs/QuickVoiceInput
   ```

3. 删除 `~/Applications/快捷语音输入.app`。
4. 在「系统设置 → 隐私与安全性 → 辅助功能」里删除它；如果开了开机启动，也到「登录项」里删除。
