# Remote DSH for macOS

Remote DSH for macOS is an unofficial community wrapper for running a remote
model through an existing SSH tunnel in a native AppKit/WebKit window. It is
unaffiliated with and unendorsed by DeepSeek, and it is not an official DeepSeek
product.

This repository contains only the macOS wrapper source. You provide and manage
the SSH configuration, remote model service, and Harness launcher yourself.

## Requirements

- macOS 14 or later on Apple Silicon
- Swift 6 toolchain
- An existing SSH alias that creates the local tunnel to the remote model
- A user-managed executable that starts the configured Harness profile

The app does not generate SSH configuration, install a Harness runtime, or
manage provider credentials. Search is neither supplied nor promised by this
project; any search capability belongs to the separately managed Harness
profile.

## Configure

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

## Run and test from source

Run directly with Swift:

```bash
swift run RemoteDSHApp
```

Run the behavioral, packaging, and privacy checks:

```bash
swift run RemoteDSHTestRunner
/bin/bash Scripts/test-public-tree.sh
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

## Ownership and privacy guarantees

The app retains exact process handles only for SSH and Harness child processes
that it starts. On quit it stops only those exact children, in Harness-then-SSH
order; it does not use process-name sweeps. If healthy services already exist,
the app attaches without claiming ownership and leaves them running on quit.

Configuration and RPC traffic remain local to the configured numeric loopback
origins. The wrapper does not contain provider credentials, collect analytics,
or send telemetry. Project content handled by Harness follows the user's
separately managed Harness and model configuration; this wrapper adds no
separate project upload.

## Release boundary and upstream

Version 0.1 is source-only. The build script creates an ad-hoc-signed local app
for personal verification; this project does not provide a notarized binary,
Developer ID distribution, updater, DMG, or release download.

The upstream runtime is
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness), distributed
separately under its
[MIT license](https://github.com/deepseek-ai/deepseek-harness/blob/master/LICENSE).
This wrapper does not embed that runtime.

## 中文使用说明

本项目是非官方、与 DeepSeek 无隶属或背书关系的 macOS 源码封装。请先自行
准备可建立远程模型隧道的 SSH alias，以及可执行的 Harness launcher；然后把
`Resources/config.example.plist` 复制到
`$HOME/Library/Application Support/RemoteDSH/config.plist` 并修改五个配置项。
可用 `swift run RemoteDSHApp` 从源码运行，或把绝对 `.app` 路径传给
`Scripts/build-app.sh` 进行本地 ad-hoc 签名构建。应用只终止自己精确启动的
子进程；已有服务只连接、不接管。项目不提供遥测、凭据管理或搜索能力保证。
