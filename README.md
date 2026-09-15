# JoplinD

自动跟踪 [laurent22/joplin](https://github.com/laurent22/joplin) 的新版本并在 GitHub Actions 里重新打包：

两个平台**共用同一个 Release**（tag 与上游一致，例如 `v3.7.18`），各自的资产互不覆盖：谁先跑完谁创建 Release，后跑的一方只往里面补自己的文件。

## 目录结构

```
.github/workflows/win-x64-repack.yml      # 每天检测 + Windows 重打包 + 发布
.github/workflows/android-arm64-release.yml  # 每天检测 + Android 编译 + 发布
scripts/repack.sh                         # Windows 核心逻辑：下载 -> 解包 -> 剔除 -> 重打包
scripts/trim-joplin-locales.js            # 裁剪 Joplin 界面翻译
```

---

## 软件更新地址

两个平台都以**本仓库**为更新地址：

```
https://api.github.com/repos/<owner>/<repo>/releases
```

工作流里写的是 `${{ github.repository }}`，会**动态取当前仓库**，所以不需要硬编码、仓库改名或换 owner 也会自动跟着走。想指向别处（例如自建镜像），只改工作流 `env` 里的 `UPDATE_FEED_URL` / `UPDATE_REPO` 一处即可。

### Windows 端（已生效）

- `scripts/repack.sh` 会把 `app.asar` 里 Joplin 内置的更新端点 `https://objects.joplinusercontent.com/r/releases` 替换成 `UPDATE_FEED_URL`；
- 同时把 `resources/app-update.yml` 的 `owner` / `repo` 改成 `UPDATE_REPO`。

### Android 端（重要说明）

**Joplin 移动端目前没有内置的应用内更新检查器**，所以 APK 里没有可替换的更新端点：

- `packages/app-mobile` 下不存在任何更新检查相关文件；
- 设置界面（`ConfigScreen`）里只有「Copy version info」和几个外链，没有「检查更新」入口；
- 官方 changelog 中也没有该功能，Android 版依赖应用商店 / Release 页面手动更新。

因此 `android-arm64-release.yml` 里的 **Point the update check at this repository** 步骤做的是：在编译前扫描 `packages/app-mobile` 源码，如果发现官方更新端点（`objects.joplinusercontent.com/r/releases`、`api.github.com/repos/laurent22/joplin-android/releases`、`api.github.com/repos/laurent22/joplin/releases`）就替换成本仓库地址；当前上游版本里找不到，于是打印一行说明并跳过。这样上游一旦加入该功能就会自动生效，不需要再改工作流。

APK 的更新来源就是本仓库的 Release 页面。用 `PATCH_UPDATE_FEED: 'false'` 可以彻底关掉这一步。

---

## 使用

### 1. 推送到 GitHub

本目录已经是一个 git 仓库，把它推到你自己的 GitHub 仓库即可（`main` 分支）。

推上去会触发一次 Android 构建（工作流带 `push` 触发器），属正常现象。

### 2. 打开写权限

`Settings → Actions → General → Workflow permissions` 选择 **Read and write permissions**，否则 `gh release create` / `gh release upload` 会失败。

### 3. 触发

| 平台 | 自动                                 | 手动 |
| --- |------------------------------------| --- |
| Windows | 每天 UTC 08:00（`cron: '23 3 * * *'`） | `Actions → Repack Joplin (win-x64, no OCR / no AI) → Run workflow`，可勾选 `force` 重打包当前版本 |
| Android | 每天 UTC 08:00（`cron: '0 2 * * *'`）  | `Actions → Build Joplin Android ARM64 → Run workflow`，可填版本号（如 `v3.7.16`），留空为最新 |

有新版本时，本仓库会出现同名 tag 的 Release，例如 `v3.7.18`。

### 4. Android 签名（可选）

默认用内置 debug 密钥签名。要用自己的正式密钥，在 `Settings → Secrets and variables → Actions` 添加：

| Secret | 说明 |
| --- | --- |
| `SIGNING_KEY` | `.jks` / `.keystore` 文件的 Base64（PowerShell：`[Convert]::ToBase64String([IO.File]::ReadAllBytes("your_key.jks"))`） |
| `KEY_STORE_PASSWORD` | 密钥库密码 |
| `ALIAS` | 别名 |
| `KEY_PASSWORD` | 别名密码 |

---

## Windows 端可调参数

都在 `win-x64-repack.yml` 的 `env` 或 `scripts/repack.sh` 里：

| 位置 | 用途 |
| --- | --- |
| `schedule.cron` | 检查频率 |
| `COMPRESS_LEVEL` | 压缩等级，`0` 最快、`9` 最小 |
| `KEEP_LOCALES` | 保留哪些 Electron 语言包，例如 `en-US.pak zh-CN.pak zh-TW.pak` |
| `KEEP_EDITOR_LOCALES` | 保留哪些 TinyMCE 语言包（glob），例如 `en* zh*` |
| `TRIM_UI_LOCALES` / `KEEP_UI_LOCALES` | Joplin 界面翻译的裁剪开关与保留前缀（默认 `en zh`） |
| `UPDATE_FEED_URL` / `UPDATE_REPO` | 更新检查地址，见上文 |
| `STRIP_AI` | 设为 `false` 可保留 AI 运行时（语义搜索继续可用） |
| `STRIP_RUNTIME_EXTRAS` / `RUNTIME_EXTRAS` | 可选：删掉 Electron 运行时里的 `dxcompiler.dll` 等大文件（默认关） |
| `scripts/repack.sh` 的 OCR 段 / AI 段 | OCR 目录与文件的匹配规则；要从 `app.asar` 里删掉的模块清单 |

Windows 端的裁剪内容：只保留 x64 载荷（丢掉 `app-32.7z` / `app-arm64.7z`）、去掉 OCR（`tesseract.js` / `tesseract.js-core` / `*.traineddata`）、从 `app.asar` 里删掉 AI 运行时（`@huggingface/transformers` 及其依赖树 `onnxruntime-*` / `sharp` / `@huggingface/jinja` / `@huggingface/tokenizers`）、Electron / TinyMCE / Joplin 界面翻译只留中英文。

---

## 说明与注意事项

- **OCR**：Joplin 通过 electron-builder 的 `extraResources` 把 `tesseract.js`、`tesseract.js-core` 放在 `resources/` 下（引擎本体约 46 MB，`.traineddata` 语言数据是运行时下载的）。删掉引擎后 OCR 不可用。
- **AI**：`onnxruntime-node` 与 `@huggingface/transformers` 支撑本地语义搜索。源码里 `LocalEmbeddingProvider` 是运行时按需加载的（`shim.onnxRuntime()` + 动态 `import()`，且都有判空），所以删除后主程序仍能正常启动，只是 AI 功能失效。
- **app.asar 会被解包再重打包**（用 `@electron/asar`），这一步是删 AI 组件必需的。
- **上游资产上传有先后**：Joplin 发布时 Windows 资产可能晚于 Release 本体出现，脚本检测到 x64 资产不存在时会打 warning 正常退出，等下一次定时运行即可。
- **共用 Release 的取舍**：两个平台共用 tag，各自只判断/覆盖自己的资产（Windows 判断 `Joplin-<ver>-win-x64-noocr-noai.7z`，Android 判断 `joplin-<ver>-arm64.apk`），因此不会互相误判成「已经打包过了」。也因此 Windows 端 `force` 时**不再删除整个 Release**（原方案会删 tag，那会把 APK 一起删掉），只重新上传自己的文件。
- **Release 说明**：谁先创建 Release，就用谁的说明；后到的一方只上传资产、不覆盖说明。
- **R8**：上游 Joplin 默认不开 minify，`proguard-rules.pro` 也只有一条 `-keep`，R8 有可能裁掉运行时需要的代码。若 APK 启动即崩，把工作流里 `android.enableMinifyInReleaseBuilds` 改回 `false`。
- **只出 7z / APK，不做自动安装更新**：Windows 产物不含 `latest.yml`，无法做真正的静默升级，新版本需要重新下载。

## 首次使用请验证

Windows 端的 AI 运行时是从 `app.asar` 里删掉的，虽然有源码层面的依据表明是懒加载，但**请务必把产物下载下来实际启动一次**，确认：

1. `Joplin.exe` 能正常启动、同步、编辑笔记；
2. 日志里没有 `Cannot find module 'onnxruntime-node'` 之类的致命错误（AI 功能报错属正常）。

若启动异常，把工作流里的 `STRIP_AI` 改成 `false` 重新打包即可。

Android 端建议装好后确认能启动、能同步，并核对 `sha256` 校验值。

## 致谢

- 原项目：[Joplin](https://github.com/laurent22/joplin) by Laurent Cozic.
- Love From AI
---

*声明：本仓库是一个独立的构建工具，与 Joplin 官方团队无直接关联。*
