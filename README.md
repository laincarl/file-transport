# 局域快传

一个面向 Windows、macOS、Android 手机和平板及 Android TV 的局域网点对点文件传输工具。设备之间直接连接，文件不经过云端或中转服务器。

## 当前功能

- 通过 UDP 广播、定向广播和 TCP 主动探测自动发现同一局域网内的设备
- 通过 IP 地址手动添加设备
- 发送单个文件、多个文件或整个文件夹
- Windows/macOS 支持拖入文件和文件夹
- 接收方确认后开始传输
- 接收端实时回传实际落盘进度与速度，双方显示口径一致，并显示预计剩余时间
- 流式读写，不在应用层限制文件大小
- 保留文件夹目录结构，重名文件自动编号
- 失败任务从头重新发送，未完成文件会被清理
- 自定义设备名称和接收目录
- 全平台默认自动接收文件，无需逐次确认；可在设置中关闭“自动接收文件”，保存后生效并记住选择
- 接收完成后可直接打开文件，或在资源管理器/Finder 中显示
- Android 默认保存到公共 `下载/局域快传` 目录，支持调用系统安装器打开 APK
- Android TV 支持电视启动器入口、遥控器方向键与确认键操作；电视端用于接收和安装 APK，同一安装包可同时安装到手机和电视
- 启动后每天自动检查一次更新，优先 Gitee、失败回退 GitHub，设置页也可手动检查；支持下载进度、SHA-256 校验并调用系统安装流程
- 桌面窗口启动时自动在当前显示器居中

## 运行

需要 Flutter 3.41 或兼容版本。

```powershell
flutter pub get
flutter run -d windows
```

连接 Android 设备后：

```powershell
flutter run -d android
```

macOS 客户端需要在 macOS 主机上构建：

```bash
flutter run -d macos
```

## 网络说明

- UDP `45678`：设备发现广播
- TCP `45679`：文件传输

第一次运行时，请允许操作系统防火墙和局域网访问提示。Android 还需要授予文件访问权限，打开 APK 时需按系统提示允许“安装未知应用”。如果路由器阻止局域网广播，可以使用“手动连接”输入对方 IP 地址。

## 首版限制

- 不支持断点续传，连接中断后需要从头发送
- 不支持公网传输、账号系统或云端中转
- 不提供加密和设备配对
- Android 后台常驻接收尚未实现，传输时请保持应用运行

## 构建产物

- `dist/局域快传-windows-x64.zip`
- `dist/局域快传-android.apk`

GitHub Actions 会在推送到 `main` 或手动运行时自动生成 Android、Windows、macOS 三个平台的流水线产物，保留 14 天。macOS 使用 DMG 磁盘映像，避免 Actions Artifact 出现双层 ZIP。推送形如 `v1.0.0` 的标签时，会自动创建 GitHub Release 并附上三个平台的安装包。

应用内更新先通过 Gitee 最新发行版 API 查找 `latest.json`；网络失败、限流、清单无效或镜像未同步完成时，回退 GitHub 最新 Release 清单。Gitee 没有比本机更新的版本时也会查询 GitHub，避免镜像延迟隐藏新版本；此时 GitHub 不通而 Gitee 有有效清单则显示无更新。下载失败、超时或校验失败时，回退 GitHub 的**同版本、同文件**，仍校验文件大小和 SHA-256，不混用最新版本安装包。发布标签必须与 `pubspec.yaml` 中的版本一致，例如应用版本为 `1.1.2+4` 时使用标签 `v1.1.2`；流水线自动生成 SHA-256 更新清单，并把相同版本写入 Windows 安装器。

## GitHub 主维护、Gitee 镜像

Gitee 镜像地址：https://gitee.com/laincarl/file-transport 。日常只在 GitHub 维护，避免在 Gitee 修改 main 或重写标签。

一次性配置：在 Gitee 创建有 `projects` 权限的专用访问令牌（Gitee 个人令牌可能覆盖账号下多个项目，建议使用只对目标仓库有写权限的专用账号），在 GitHub 仓库 **Settings → Secrets and variables → Actions** 添加 `GITEE_TOKEN`。不要提交令牌到仓库，也不要放进客户端。

默认 Git 推送用户名为 `laincarl`；若令牌属于另一个专用账号，额外添加 Actions Variable `GITEE_USERNAME` 为该账号用户名，并确保它有目标仓库的写权限。

- 推送 main / v* 标签：独立任务同步 main 和全部标签，不使用强推、不删除远端引用。
- GitHub 标签构建发布成功后：下载 GitHub Release 原包，校验清单后上传 Gitee，复制发行版标题、说明和预发布状态；镜像清单链接改为 Gitee。
- 用户手动发布 GitHub Release 也会触发同步；Actions 自己创建的 Release 不触发 release 事件，因此构建工作流内另有明确的同步任务。
- 新 Gitee Release 先标记为预发布，安装包全部上传、清单最后上传后才标记为正式发布。失败可以重跑；已存在的附件跳过，相同标签的安装包哈希变更则拒绝覆盖，应使用新版本标签。
- 手动补同步：Actions → “手动补同步 Gitee” → Run workflow，填写已发布标签（如 `v1.1.2`）。
- Gitee 无令牌、同步冲突或上传失败会使同步任务失败，但不会撤销已成功发布的 GitHub Release；客户端仍可回退 GitHub。

当前 Gitee 普通仓库单附件限制 100MB、总附件容量 1GB，需要定期管理旧版本容量。自动化不会删除旧发行版。客户端匿名访问 Gitee API，也可能受到服务端限流，故保留 GitHub 备选。配置凭证后请运行一次手动补同步确认真实写入权限；本地模拟测试不等同于真实 CI 验证。

Android 流水线使用保存在 GitHub Secrets 中的固定 Release 密钥签名，并以 Actions 运行编号生成递增的 `versionCode`，因此后续流水线 APK 可以直接覆盖升级。首次从旧的 Debug 签名版切换到 Release 签名版时，需要先卸载旧版本。请勿替换或遗失原始签名密钥，否则无法继续覆盖升级已有安装。

Windows 流水线同时生成免安装 ZIP 和带卸载入口的 EXE 安装程序。安装程序会添加 UDP `45678` 与 TCP `45679` 的 Windows 防火墙入站规则，卸载时自动移除。

## 已验证

- Windows 11 与 Android API 35 模拟器双向传输成功
- 中文文件名和中文文本内容可正常传输
- 双向接收文件与源文件 SHA-256 一致
- Android 公共下载目录、APK 安装器与文件管理器跳转均已在 API 35 模拟器验证
- Android 固定签名 APK 的连续版本覆盖安装已在 API 35 模拟器验证
- Android TV 启动入口、1080p 横屏布局、遥控器确认接收、APK 落盘和系统安装器跳转已在 Android TV API 36 模拟器验证
- Android 模拟器不支持局域网广播时，可通过 `10.0.2.2` 手动连接宿主机
