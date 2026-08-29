# Remote DSH for macOS

[English](#english) | [简体中文](#简体中文)

<a id="english"></a>

## English

Remote DSH for macOS is an unofficial community wrapper for running a remote
model through an existing SSH tunnel in a native AppKit/WebKit window. It is
unaffiliated with and unendorsed by DeepSeek, and it is not an official DeepSeek
product.

This repository contains only the macOS wrapper source. You provide and manage
the SSH configuration, remote model service, and Harness launcher yourself.

### Requirements

- macOS 14 or later on Apple Silicon
- Swift 6 toolchain
- An existing SSH alias that creates the local tunnel to the remote model
- A user-managed executable that starts the configured Harness profile

The app does not generate SSH configuration, install a Harness runtime, or
manage provider credentials. Search is neither supplied nor promised by this
project; any search capability belongs to the separately managed Harness
profile.

### Configure

Install and edit the source-only example:

```bash
mkdir -p "$HOME/Library/Application Support/RemoteDSH"
cp Resources/config.example.plist \
  "$HOME/Library/Application Support/RemoteDSH/config.plist"
${EDITOR:-vi} "$HOME/Library/Application Support/RemoteDSH/config.plist"
```

The exact runtime path is
`$HOME/Library/Application Support/RemoteDSH/config.plist`. Set `sshAlias` to an
existing alias, set the two loopback ports, and set `harnessLauncherPath` to an
absolute executable path or a path beginning with `~/`. The configuration has
no credential fields.

### Run and test from source

Run directly with Swift:

```bash
swift run RemoteDSHApp
```

Run the behavioral, packaging, and privacy checks:

```bash
swift run RemoteDSHTestRunner
/bin/bash Scripts/test-public-tree.sh
/bin/bash Scripts/test-public-history.sh
/bin/bash Scripts/test-atomic-install.sh
/bin/bash Scripts/test-build-app.sh
/bin/bash Scripts/verify-public-tree.sh .
/bin/bash Scripts/verify-public-history.sh .
```

Build an ad-hoc-signed local app only at an explicit absolute destination, then
verify and launch that local copy:

```bash
temporary_root="$(mktemp -d)"
/bin/bash Scripts/build-app.sh \
  "$temporary_root/Remote DSH for macOS.app"
/bin/bash Scripts/verify-bundle.sh \
  "$temporary_root/Remote DSH for macOS.app"
open "$temporary_root/Remote DSH for macOS.app"
```

`build-app.sh` never chooses an Applications directory for you. When replacing
an existing explicit destination, it retains the previous bundle under the
destination parent's `.remote-dsh-backups` directory.

### Ownership and privacy guarantees

The app retains exact process handles only for SSH and Harness child processes
that it starts. On quit it stops only those exact children, in Harness-then-SSH
order; it does not use process-name sweeps. If healthy services already exist,
the app attaches without claiming ownership and leaves them running on quit.

Configuration and RPC traffic remain local to the configured numeric loopback
origins. The wrapper does not contain provider credentials, collect analytics,
or send telemetry. Project content handled by Harness follows the user's
separately managed Harness and model configuration; this wrapper adds no
separate project upload.

### Release boundary and upstream

Version 0.1 is source-only. The build script creates an ad-hoc-signed local app
for personal verification; this project does not provide a notarized binary,
Developer ID distribution, updater, DMG, or release download.

The upstream runtime is
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness), distributed
separately under its
[MIT license](https://github.com/deepseek-ai/deepseek-harness/blob/master/LICENSE).
This wrapper does not embed that runtime.

---

<a id="简体中文"></a>

## 简体中文

Remote DSH for macOS 是一个非官方社区封装，用于在原生 AppKit/WebKit 窗口中，
通过已有的 SSH 隧道运行远程模型。本项目与 DeepSeek 没有隶属关系，也未获得其
背书，不是 DeepSeek 官方产品。

本仓库只包含 macOS 封装的源代码。SSH 配置、远程模型服务和 Harness 启动器均由
用户自行提供和管理。

### 系统要求

- 搭载 Apple Silicon 的 macOS 14 或更高版本
- Swift 6 工具链
- 一个能够为远程模型建立本地隧道的现有 SSH alias
- 一个由用户管理、用于启动指定 Harness 配置的可执行文件

本应用不会生成 SSH 配置、安装 Harness 运行时或管理模型服务商凭据。本项目既不
提供也不承诺搜索能力；任何搜索功能都属于用户单独管理的 Harness 配置。

### 配置

复制并编辑仅供源码使用的配置示例：

```bash
mkdir -p "$HOME/Library/Application Support/RemoteDSH"
cp Resources/config.example.plist \
  "$HOME/Library/Application Support/RemoteDSH/config.plist"
${EDITOR:-vi} "$HOME/Library/Application Support/RemoteDSH/config.plist"
```

实际运行时配置路径为
`$HOME/Library/Application Support/RemoteDSH/config.plist`。请将 `sshAlias`
设置为已有的 SSH alias，设置两个本地回环端口，并将 `harnessLauncherPath` 设置为
绝对可执行文件路径或以 `~/` 开头的路径。该配置不包含任何凭据字段。

### 从源码运行和测试

使用 Swift 直接运行：

```bash
swift run RemoteDSHApp
```

运行行为、打包和隐私检查：

```bash
swift run RemoteDSHTestRunner
/bin/bash Scripts/test-public-tree.sh
/bin/bash Scripts/test-public-history.sh
/bin/bash Scripts/test-atomic-install.sh
/bin/bash Scripts/test-build-app.sh
/bin/bash Scripts/verify-public-tree.sh .
/bin/bash Scripts/verify-public-history.sh .
```

仅在明确指定的绝对路径构建本地 ad-hoc 签名 App，然后验证并打开该副本：

```bash
temporary_root="$(mktemp -d)"
/bin/bash Scripts/build-app.sh \
  "$temporary_root/Remote DSH for macOS.app"
/bin/bash Scripts/verify-bundle.sh \
  "$temporary_root/Remote DSH for macOS.app"
open "$temporary_root/Remote DSH for macOS.app"
```

`build-app.sh` 不会自行选择 Applications 目录。替换用户明确指定的现有目标时，
脚本会把旧 App 保留在目标父目录下的 `.remote-dsh-backups` 目录中。

### 进程所有权与隐私保证

应用只保存它亲自启动的 SSH 和 Harness 子进程的精确句柄。退出时，它只按照先
Harness、后 SSH 的顺序停止这些子进程，不会按进程名批量扫描或终止。如果已有
健康服务正在运行，应用只连接而不接管所有权，并会在退出时保留这些服务。

配置和 RPC 流量仅限于已配置的数字形式本地回环地址。本封装不包含模型服务商凭据，
不收集分析数据，也不发送遥测。Harness 处理的项目内容遵循用户单独管理的 Harness
和模型配置；本封装不会额外上传项目内容。

### 发布边界与上游项目

0.1 版本仅发布源代码。构建脚本可生成供个人验证使用的本地 ad-hoc 签名 App；
本项目不提供经过公证的二进制文件、Developer ID 分发、自动更新器、DMG 或可下载
的发行版。

上游运行时为
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)，由上游根据
[MIT 许可证](https://github.com/deepseek-ai/deepseek-harness/blob/master/LICENSE)
单独分发。本封装不会嵌入该运行时。
