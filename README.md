# Core Loader

PHP 扩展一键安装（PHP 7.0–8.5 · Linux / macOS / Windows）

## 安装

**Linux / macOS**

```bash
curl -fsSL https://raw.githubusercontent.com/coreloader/coreloader/main/install.sh | bash
```

**Windows（PowerShell）**

```powershell
irm https://raw.githubusercontent.com/coreloader/coreloader/main/install.ps1 | iex
```

脚本会自动：下载扩展 → 写入配置 → 重载 PHP。

宝塔等多 PHP 版本时指定版本：

```bash
curl -fsSL https://raw.githubusercontent.com/coreloader/coreloader/main/install.sh \
  | bash -s -- --php 8.5
```

## 验证

```bash
php -m | grep core_loader
```

## 手动下载

→ [Releases](https://github.com/coreloader/coreloader/releases)
