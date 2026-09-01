# Core Loader

预编译 PHP 扩展一键安装（**不包含源码**）。支持 **PHP 7.0–8.5**，覆盖 Linux / macOS / Windows。

仓库：https://github.com/coreloader/coreloader

## 一键安装

### Linux / macOS

```bash
curl -fsSL https://raw.githubusercontent.com/coreloader/coreloader/main/install.sh | bash
```

指定版本：

```bash
curl -fsSL https://raw.githubusercontent.com/coreloader/coreloader/main/install.sh \
  | bash -s -- --version v8.0.0
```

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/coreloader/coreloader/main/install.ps1 | iex
```

## 配置

安装后在 `php.ini` 中启用（**必须用 `extension=`，不要用 `zend_extension=`**）：

```ini
extension=core_loader.so
; Windows:
; extension=php_core_loader.dll
```

验证：

```bash
php -m | grep core_loader
php -r 'var_export(extension_loaded("core_loader")); echo PHP_EOL;'
```

与 OPcache 同时开启时：保持两者均为 `extension=` 加载即可；Core Loader 在编译阶段解密后再进入正常编译链，可被 OPcache 缓存。

## 支持矩阵

| PHP | Linux arm64 | Linux x86_64 | macOS arm64 | macOS x86_64 | Windows x64 | Windows x86 |
|-----|:-----------:|:------------:|:-----------:|:------------:|:-----------:|:-----------:|
| 7.0–8.5 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

产物命名示例：

- `core_loader-php8.3-linux-arm64.so`
- `core_loader-php8.3-darwin-x86_64.so`
- `php_core_loader-php8.3-win-x64.dll`

完整文件见 [Releases](https://github.com/coreloader/coreloader/releases)。

## 手动下载

打开 [Releases](https://github.com/coreloader/coreloader/releases)，按本机 PHP 版本、操作系统与架构下载对应文件，复制到 `extension_dir`，并在 `php.ini` 中配置 `extension=`。

## 故障排查

| 现象 | 处理 |
|------|------|
| 下载 404 | 确认 Release 已发布，且 PHP/OS/架构有对应附件 |
| `undefined symbol` / 无法加载 | PHP 次版本必须与产物一致（如 8.2 不能加载 8.3 的 `.so`） |
| Linux `GLIBC_2.xx not found` | 7.0–8.0 产物基于 Debian bullseye（glibc 2.31）；过旧系统需升级 glibc 或换运行环境 |
| 架构不匹配 | Apple Silicon 用 `darwin-arm64`；Intel 用 `darwin-x86_64` / `linux-x86_64` |
| 已存在旧文件 | 加 `--force`（Unix）或 `-Force`（Windows） |

## 安装脚本选项

```text
--owner NAME     默认 coreloader
--repo NAME      默认 coreloader
--version TAG    latest 或 v8.0.0
--php X.Y        默认自动检测
--dir PATH       安装目录（默认 php-config --extension-dir）
--dry-run        只打印不安装
--force          覆盖已有文件
```

## 说明

本仓库托管安装脚本与 Release 预编译附件。构建工具链与完整源码不在此公开。
