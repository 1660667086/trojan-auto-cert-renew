# Trojan 自动证书续签

这个仓库把 Trojan 自带的 `trojan tls` 证书申请工具包了一层自动化：

- 自动识别 Trojan 配置里的域名
- 证书快过期时才续签，默认提前 7 天
- 续签前自动停止占用端口的服务
- 续签后自动恢复原本正在运行的服务
- 没有 `nginx` / `cloudreve` 也能用，只运行 `trojan` 的服务器也能跑
- 失败时恢复 Trojan 原配置，避免写入坏证书路径

## 一键安装

公开仓库：

```bash
git clone https://github.com/1660667086/trojan-auto-cert-renew.git
cd trojan-auto-cert-renew
bash install.sh
```

也可以直接运行 raw 安装入口：

```bash
curl -fsSL https://raw.githubusercontent.com/1660667086/trojan-auto-cert-renew/main/install.sh | bash
```

私有仓库可以按你自己的 Token 拉取方式克隆后运行：

```bash
cd trojan-auto-cert-renew
bash install.sh
```

安装后会生成：

```text
/usr/local/sbin/trojan-auto-cert-renew
/etc/cron.d/trojan-auto-cert-renew
/var/log/trojan-auto-cert-renew.log
/root/trojan-cert-backups/
```

默认每天 `04:17` 检查一次。

安装完成后会直接打印：

```text
[OK] 安装成功
[OK] 定时任务已安装
[OK] 证书已安装且有效
到期时间: ...
```

如果当前服务器还没有有效证书，会提示：

```text
[WARN] 安装已完成，但当前没有检测到有效证书
需要立即申请/测试时运行: /usr/local/sbin/trojan-auto-cert-renew --force
```

## 手动测试

查看安装和证书状态：

```bash
/usr/local/sbin/trojan-auto-cert-renew --status
```

只检测自动识别是否正常，不申请证书：

```bash
/usr/local/sbin/trojan-auto-cert-renew --dry-run
```

强制走一次续签流程：

```bash
/usr/local/sbin/trojan-auto-cert-renew --force
```

## 自定义参数

提前 15 天续签：

```bash
RENEW_DAYS=15 bash install.sh
```

指定域名和配置文件：

```bash
DOMAIN=www.example.com CONFIG_PATH=/usr/local/etc/trojan/config.json bash install.sh
```

只管理 Trojan 服务：

```bash
SERVICE_STOP_LIST="trojan" bash install.sh
```

安装时传入的 `DOMAIN`、`CONFIG_PATH`、`TROJAN_CLI`、`SERVICE_STOP_LIST`、`RENEW_DAYS` 会写入定时任务。后面要修改，可以编辑：

```text
/etc/cron.d/trojan-auto-cert-renew
```

## 自动识别规则

脚本会按顺序查找域名：

1. 环境变量 `DOMAIN`
2. Trojan JSON 配置里的 `ssl.sni`
3. 其他常见字段：`sni`、`server_name`、`domain`、`host`
4. `trojan info` 分享链接里的域名

脚本会按顺序查找配置：

1. 环境变量 `CONFIG_PATH`
2. `trojan` / `trojan-go` systemd 服务里的 `-config` 参数
3. 常见配置路径：
   `/usr/local/etc/trojan/config.json`
   `/usr/local/etc/trojan-go/config.json`
   `/etc/trojan/config.json`
   `/etc/trojan-go/config.json`

## 注意

这个方案使用 Trojan 自带工具的 Let's Encrypt standalone 模式，所以续签时必须短暂释放 `80` 端口。脚本会自动停止当前正在运行且存在的服务，例如：

```text
trojan
trojan-go
nginx
caddy
apache2
httpd
cloudreve
```

没有安装的服务会自动忽略。

当前无人值守模式只自动选择 Trojan 菜单里的：

```text
1. Let's Encrypt 证书
```

`ZeroSSL` / `BuyPass` 会额外询问邮箱，不适合这个自动脚本。

安装脚本默认会移除 `acme.sh` 自己添加的 cron 续签任务，因为那个任务不会先停端口，容易续签失败。需要保留的话：

```bash
DISABLE_ACME_CRON=0 bash install.sh
```

## 卸载

```bash
bash uninstall.sh
```
