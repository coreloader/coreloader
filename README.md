# Core Loader

PHP 扩展一键安装脚本（PHP 7.0–8.5 · Linux / macOS / Windows）

技术文档：https://coreloader.com/docs

## 安装

**Linux / macOS**

```bash
curl -fsSL https://coreloader.com/core-loader-releases/install.sh | bash
```

指定 PHP 版本：

```bash
curl -fsSL https://coreloader.com/core-loader-releases/install.sh | bash -s -- 8.5
```

**Windows（CMD / PowerShell）**

```bat
cmd /c "curl -fsSL -o %TEMP%\cl-install.cmd https://coreloader.com/core-loader-releases/install.cmd && call %TEMP%\cl-install.cmd"
```

指定 PHP 版本：

```bat
cmd /c "curl -fsSL -o %TEMP%\cl-install.cmd https://coreloader.com/core-loader-releases/install.cmd && call %TEMP%\cl-install.cmd 8.5"
```

#### 脚本会自动：下载扩展 → 写入配置 → 重载 PHP。

## 验证

本机：

```bash
php -m | grep core_loader
```

Docker：

```bash
docker exec <容器名> php -m | grep core_loader
```

## 手动下载

- 主站：https://coreloader.com/extend
- 备用：https://github.com/coreloader/coreloader/releases
