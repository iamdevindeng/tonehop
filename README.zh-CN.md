# ToneHop

[English](README.md) | **简体中文**

ToneHop 是一款原生 macOS 菜单栏应用。你可以用它切换音频输出设备、调节设备音量，并设置全局快捷键。应用使用 SwiftUI、AppKit 和 Core Audio 构建。

- 从菜单栏选择输出设备。ToneHop 会在系统确认后显示切换结果。
- 如果设备提供受支持的音量控制接口，即可调节该设备的音量。
- 为每台设备设置快捷键。设备不可用时，ToneHop 会保留已保存的快捷键。
- 支持英语和简体中文界面。设备名称保留原始文字。

**[下载适用于 Apple 芯片的 ToneHop v0.1.0](https://github.com/iamdevindeng/tonehop/releases/tag/v0.1.0)** · [所有版本](https://github.com/iamdevindeng/tonehop/releases)

## 下载与安装（普通用户）

前往[发布页面](https://github.com/iamdevindeng/tonehop/releases)，下载对应安装包：

- **macOS（Apple 芯片）：** [`ToneHop-0.1.0-arm64.dmg`](https://github.com/iamdevindeng/tonehop/releases/download/v0.1.0/ToneHop-0.1.0-arm64.dmg)。

**系统要求：** 搭载 Apple 芯片的 Mac，以及 macOS **27.0 或更高版本**。目前仅验证了 macOS 27.0.1；其他 macOS 版本和硬件尚未验证。无需安装 Xcode。

**安装或更新：** 如果 ToneHop 正在运行，请通过菜单栏菜单退出。完成可能出现的退出确认，并等待所需的 AirPlay 清理完成。打开 DMG，将 **ToneHop.app** 拖入 **Applications（应用程序）**。如果提示已有旧版本，请替换。推出 DMG 后，从“应用程序”打开 ToneHop。

**首次启动：** 此版本采用临时签名（ad-hoc），**未经 Developer ID 签名，也未经 Apple 公证**。如果 macOS 无法验证开发者，且你信任下载来源，请先尝试打开 ToneHop。然后前往 **系统设置 → 隐私与安全性 → 仍要打开**，并确认**打开**。此例外仅适用于 ToneHop。详见 [Apple 的说明](https://support.apple.com/zh-cn/102445)。如果 macOS 提示存在恶意软件或应用已损坏，请停止操作，检查下载文件。

ToneHop 在菜单栏中运行。启动时不会打开主窗口，也不会更改音频输出。设备控制和快捷键说明见[初次使用](#初次使用)。

<details>
<summary>验证下载文件（可选）</summary>

从同一发布页面下载配套的 `.sha256` 文件，并将其与 DMG 放在同一文件夹中。在该文件夹中打开终端，运行：

```sh
shasum -a 256 -c ToneHop-0.1.0-arm64.dmg.sha256
```

预期结果为 `ToneHop-0.1.0-arm64.dmg: OK`。请使用与你下载版本对应的文件名。

</details>

## 从源码构建（开发者）

原生工程位于 `ToneHop/ToneHop.xcodeproj`，使用 `ToneHop` scheme。请安装包含 **macOS 27.0 SDK** 的完整 **Xcode 27.0** 应用，这是本项目已验证的工具链。最低部署目标为 macOS 27.0，无需第三方依赖。

运行开发版应用前，请先退出已安装的其他副本，避免多个副本争用快捷键配置。

```sh
# 检查当前启用的工具链
xcodebuild -version
xcrun --sdk macosx --show-sdk-version

# 克隆仓库
git clone https://github.com/iamdevindeng/tonehop.git
cd tonehop

# 在仓库根目录构建、运行和测试
./script/build_and_run.sh --build-only  # 构建 Debug，不停止或启动应用
./script/build_and_run.sh              # 构建并启动或重启当前检出目录中的应用
./script/build_and_run.sh --verify     # 同时验证已启动进程的路径
./script/test.sh                       # 使用模拟音频提供方，在宿主中运行 XCTest
```

你也可以在 Xcode 中打开工程，并选择 `ToneHop` scheme。

**输出路径：** `build/Build/Products/Debug/ToneHop.app`。日志和测试结果保存在 `build/` 下，Git 会忽略此目录。

**验证范围：** `--verify` 检查进程路径，不验证界面或音频行为。测试使用模拟音频提供方。测试宿主不会启动真实音频服务，也不会切换系统音频输出。

<details>
<summary>构建 Release 应用或 DMG</summary>

在仓库根目录运行以下命令。命令会创建新的构建目录，并构建 arm64 Release 应用：

```sh
mkdir -p build
TONEHOP_DERIVED_DATA="$(mktemp -d "$PWD/build/source-release.XXXXXX")"
xcodebuild -project ToneHop/ToneHop.xcodeproj \
  -scheme ToneHop -configuration Release -sdk macosx \
  -destination 'platform=macOS' \
  -derivedDataPath "$TONEHOP_DERIVED_DATA" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  DEPLOYMENT_POSTPROCESSING=YES DEPLOYMENT_LOCATION=NO \
  STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=debugging build

open "$TONEHOP_DERIVED_DATA/Build/Products/Release"
```

最后一条命令会打开构建文件夹。

1. 通过菜单退出所有正在运行的 ToneHop 实例。
2. 将 `ToneHop.app` 复制到“应用程序”。

这些构建采用临时签名，未经 Developer ID 签名或 Apple 公证。上文的首次启动说明也适用于下载的副本。

运行以下命令，将构建好的应用与 MIT 许可证打包，并生成 SHA-256 校验文件：

```sh
./script/package_dmg.sh \
  "$TONEHOP_DERIVED_DATA/Build/Products/Release/ToneHop.app" \
  "$TONEHOP_DERIVED_DATA/dist/ToneHop-0.1.0-arm64.dmg"
```

打包脚本不会构建或启动应用。它会拒绝覆盖已有的输出文件。

</details>

## 初次使用

切换音频输出：

1. 点击菜单栏图标，打开设备列表。
2. 点击设备名称。

启动 ToneHop 不会更改当前输出。

退出应用：

1. 右键点击菜单栏图标。
2. 选择**退出**。

如果同时满足以下条件，ToneHop 会为 Mac 的内置扬声器分配 **Control + Shift + 1**：

- 尚无快捷键配置。
- ToneHop 能可靠识别内置扬声器。

其他设备默认没有快捷键。你可以修改或清除此快捷键。已有的空配置会保持为空。

设置快捷键：

1. 点击快捷键输入框。
2. 按下包含 **Command 或 Control** 的组合键。

组合键也可以包含 Option 和 Shift。要清除快捷键，请在输入框中按 Backspace。要取消，请按 Escape。设备不可用时，ToneHop 会保留已保存的快捷键。

界面使用 macOS 为 ToneHop 选择的语言。如果该语言不可用，ToneHop 会使用英语。

更改语言：

1. 在 macOS 设置中选择应用语言。
2. 重启 ToneHop。

## AirPlay 与其他限制

### AirPlay

**AirPlay 使用私有 API。** 系统更新可能改变或破坏设备发现、切换或音量控制功能。macOS 最低部署版本不保证所有 AirPlay 功能都能在每个受支持的系统版本上正常工作。

部分 AirPlay 设备需要先在 **ToneHop 运行期间**，通过 macOS 的“声音”菜单选择一次。在 ToneHop 获得足够信息以安全切换之前，该设备会在列表中保持禁用状态。

在未事先捕获引用的情况下，ToneHop 仅在同时满足以下条件时启用已有 AirPlay 流的恢复：

- Mac 运行 **macOS 27.0.1**。其他版本均未启用此恢复机制。
- 所需的身份与输出检查通过。

此恢复机制不会在启动时自动切换输出。

如果 ToneHop 创建的 AirPlay 流需要清理，应用会在退出时要求确认。确认内容包括切换到 Mac 的内置扬声器，并移除该流。取消后应用会继续运行。

ToneHop 只会移除能确认由自身创建的流。它不会移除系统或其他应用创建的流。如果无法确认切换或清理完成，ToneHop 会保持运行。

### 音量与输出

音量支持取决于设备和可用的系统控制接口。ToneHop 无法调节部分设备的音量。更改音量不会连接或切换到该设备。

切换操作会更改默认媒体输出，不会更改系统音效输出。

### 权限与验证

当前应用不需要辅助功能自动化权限或麦克风权限。应用包含用于设备发现的本地网络权限用途说明。我们尚未在全新账户上验证首次权限提示和拒绝权限后的行为。

以下项目尚未验证：

- 更多设备的兼容性。
- 睡眠与网络变化。
- 长时间运行。
- 完整的辅助功能覆盖。

自动化测试不能替代这些实机检查。

## 许可证

[MIT](LICENSE). Copyright (c) 2026 ToneHop contributors.
