# Core Loader

PHP 扩展一键安装（PHP 7.0–8.5 · Linux / macOS / Windows）

## 安装

**Linux / macOS**

```bash
curl -fsSL https://coreloader.com/core-loader-releases/install.sh | bash
```

**Windows（PowerShell）**

```powershell
irm https://coreloader.com/core-loader-releases/install.ps1 | iex
```

脚本会自动：下载扩展 → 写入配置 → 重载 PHP。

多 PHP 版本时指定：

```bash
curl -fsSL https://coreloader.com/core-loader-releases/install.sh \
  | bash -s -- --php 8.5
```

## 验证

```bash
php -m | grep core_loader
```

## 手动下载

- 主站：https://coreloader.com/extend
- 备用：https://github.com/coreloader/coreloader/tree/main/download
