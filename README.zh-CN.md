# ToneHop

[English](README.md) | **简体中文**

一款原生 macOS 菜单栏应用，可切换音频输出设备、调节设备音量，并为设备设置全局快捷键。使用 SwiftUI、AppKit 和 Core Audio 构建。

- 从菜单栏选择输出设备，并查看系统确认的切换结果。
- 当设备提供受支持的音量控制接口时，可调节该设备的音量。
- 为每台设备设置快捷键。设备不可用时，快捷键绑定仍会保留。
- 支持英语和简体中文界面。设备名称保留原始文字。

**[下载适用于 Apple 芯片的 ToneHop v0.1.0](https://github.com/iamdevindeng/tonehop/releases/tag/v0.1.0)** · [所有版本](https://github.com/iamdevindeng/tonehop/releases)

## 下载与安装（普通用户）

**需要搭载 Apple 芯片的 Mac，以及 macOS 27.0 或更高版本。** 应用已在 macOS 27.0.1 上验证；其他硬件和 macOS 版本尚未验证。使用 DMG 安装包无需安装 Xcode。

1. 前往 [v0.1.0 发布页面](https://github.com/iamdevindeng/tonehop/releases/tag/v0.1.0)，下载 **`ToneHop-0.1.0-arm64.dmg`**。
2. 如果 ToneHop 正在运行，请通过菜单栏菜单退出，并完成可能出现的退出确认。打开 DMG，将 **ToneHop.app** 拖入 **Applications（应用程序）**；如果提示已有旧版本，请替换。
3. 推出 DMG，然后从“应用程序”打开 ToneHop。它的图标会出现在菜单栏中；启动时不会打开主窗口，也不会更改音频输出。

**首次启动：** 此版本采用临时签名（ad-hoc），**未经 Developer ID 签名，也未经 Apple 公证**。如果 macOS 因无法验证开发者而阻止打开，请先尝试打开 ToneHop，再前往 **系统设置 → 隐私与安全性 → 仍要打开**，并按提示确认。只有在信任下载来源时，才应为此应用设置例外；详见 [Apple 的说明](https://support.apple.com/en-us/102445)。如果 macOS 提示存在恶意软件或应用已损坏，请停止操作并检查下载文件。

<details>
<summary>验证下载文件（可选）</summary>

从同一发布页面下载配套的 `.sha256` 文件，将其与 DMG 放在同一文件夹中。在该文件夹中打开终端并运行：

```sh
shasum -a 256 -c ToneHop-0.1.0-arm64.dmg.sha256
```

预期结果为 `ToneHop-0.1.0-arm64.dmg: OK`。请使用与你下载版本对应的文件名。

</details>

## 从源码构建（开发者）

安装包含 **macOS 27.0 SDK** 的完整 **Xcode 27.0** 应用，这是本项目已验证的工具链。最低部署目标为 macOS 27.0，应用没有第三方依赖。检查当前启用的工具链，然后克隆仓库：

```sh
xcodebuild -version
xcrun --sdk macosx --show-sdk-version

git clone https://github.com/iamdevindeng/tonehop.git
cd tonehop
```

在 Xcode 中打开 `ToneHop/ToneHop.xcodeproj`，选择 `ToneHop` scheme，或在仓库根目录运行以下命令：

```sh
./script/build_and_run.sh --build-only  # 构建 Debug，不停止或启动应用
./script/build_and_run.sh              # 构建并启动或重启当前检出目录中的应用
./script/build_and_run.sh --verify     # 同时验证已启动进程的路径
./script/test.sh                       # 使用模拟音频提供方，在宿主中运行 XCTest
```

运行开发版应用前，请先退出已安装的其他副本，避免多个实例争用快捷键配置。测试宿主会跳过真实音频服务的启动；测试不会切换系统音频输出。`--verify` 检查的是进程路径，不验证界面或音频行为。

Debug 应用的输出路径为 `build/Build/Products/Debug/ToneHop.app`。日志和测试结果保存在 `build/` 下，该目录已被 Git 忽略。

<details>
<summary>构建 Release 应用或 DMG</summary>

在仓库根目录创建一个新的构建目录，并构建 arm64 Release 应用：

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

最后一条命令会打开构建文件夹。将 `ToneHop.app` 复制到“应用程序”前，请通过菜单退出所有正在运行的 ToneHop 实例。这些构建采用临时签名，未经 Developer ID 签名或 Apple 公证；上文的首次启动说明也适用于下载的副本。

使用以下命令，将构建好的应用与 MIT 许可证打包，并生成 SHA-256 校验文件：

```sh
./script/package_dmg.sh \
  "$TONEHOP_DERIVED_DATA/Build/Products/Release/ToneHop.app" \
  "$TONEHOP_DERIVED_DATA/dist/ToneHop-0.1.0-arm64.dmg"
```

打包过程不会构建或启动应用，也不会覆盖已有的输出文件。

</details>

## 初次使用

点击菜单栏图标打开设备列表，再点击设备名称切换输出。启动 ToneHop 不会更改当前输出。右键点击菜单栏图标可退出应用。

如果尚无快捷键配置，且 ToneHop 能可靠识别 Mac 的内置扬声器，它会为内置扬声器分配 **Control + Shift + 1**。其他设备默认没有快捷键。你可以修改或清除此绑定；已有的空配置会保持为空。

要设置快捷键，请点击快捷键输入框，然后按下包含 **Command 或 Control** 的组合键，也可以同时包含 Option 和 Shift。在输入框中按 Backspace 可清除快捷键，按 Escape 可取消。设备不可用时，已保存的快捷键不会被删除。

界面使用 macOS 为 ToneHop 选择的语言，无法匹配时使用英语。在 macOS 设置中选择应用语言后，重启 ToneHop 即可生效。

## AirPlay 与其他限制

- **AirPlay 依赖私有 API。** 系统更新可能改变或破坏设备发现、切换或音量控制功能。macOS 最低部署版本不代表所有 AirPlay 功能都能在每个受支持的系统版本上正常工作。
- 部分 AirPlay 设备需要先在 **ToneHop 运行期间**，通过 macOS 的“声音”菜单选择一次。在 ToneHop 获得足够信息以安全切换之前，该设备会在列表中保持禁用状态。
- 在未事先捕获引用的情况下恢复已有 AirPlay 流，目前**仅在 macOS 27.0.1 上启用**，且必须通过所需的身份与输出检查。这一机制不会在启动时自动切换输出。
- 如果 ToneHop 创建了需要清理的 AirPlay 流，退出时会请求确认切换到 Mac 内置扬声器并移除该流。取消后应用会继续运行。ToneHop 只会移除能确认由自身创建的流，不会移除系统或其他应用创建的流。如果无法确认切换或清理完成，应用会保持运行。
- 音量支持取决于设备和可用的系统控制接口。部分设备无法在 ToneHop 中调节音量。更改音量不会连接或切换到该设备。
- 切换操作会更改默认媒体输出，不会同时更改系统音效输出。
- 当前应用不需要辅助功能自动化权限或麦克风权限。应用包含用于设备发现的本地网络权限用途说明；尚未在全新账户上验证首次权限提示和拒绝权限后的行为。
- 更多设备、睡眠与网络变化、长时间运行以及完整的辅助功能覆盖仍未验证。自动化测试不能替代这些实机检查。

## 许可证

[MIT](LICENSE). Copyright (c) 2026 ToneHop contributors.
