## 1Panel 工具包

### restore-1panel.sh

新部署或整体迁移服务器时，在目标 Linux 服务器上，无需使用官方安装脚本先安装 1Panel，再恢复快照，仅凭 1Panel v2 快照文件就能还原 1Panel

<details>
<summary>使用方法</summary>

```
用法:
  bash <(curl -sSL https://fastly.jsdelivr.net/gh/pooneyy/1panel-untils@main/scripts/restore-1panel.sh) -f <快照.tar.gz> [-p <压缩密码>] [选项]

选项:
  -f FILE             快照文件路径 (必填，文件名形如 1panel-core-v2.x.x-linux-amd64-*.tar.gz)
  -p PASSWORD         创建快照时设置的压缩密码 (未设置密码则省略)
  -y                  非交互模式，所有确认默认通过
  --skip-apps         还原数据后不自动 docker compose up 拉起应用
  --install-docker    未安装 docker 时直接安装；未指定则交互式询问
  --no-show-password  隐藏明文密码，显示 ********** (默认显示明文)
  -h, --help          显示帮助
```

</details>

### update-1panel.sh

脱离 Web 面板，独立升级 / 回滚 1Panel v2 (主节点)

专业版用户在“节点管理”中勾选自动升级的节点，将在主节点升级完成后自动开始升级

<details>
<summary>使用方法</summary>

```
用法:
  bash <(curl -sSL https://fastly.jsdelivr.net/gh/pooneyy/1panel-untils@main/scripts/update-1panel.sh) [选项]

版本选择
  -v, --version <vX.Y.Z>   指定目标版本 (默认查询官方 latest)
  -m, --mode <stable|beta> 发布通道，默认 stable
  -e, --edition <cn|intl>  发行版，默认从 1pctl 的 PANEL_EDITION 读取
      --repo-url <URL>     自定义资源站根地址
  -f, --file <path>        使用本地离线安装包 .tar.gz
      --sha256 <HEX>       校验安装包 SHA256 (可选)

环境
  -b, --base-dir <dir>     覆盖安装根目录
  -p, --proxy <URL>        下载代理

行为
  -c, --check              只检查版本，不做任何改动
  -n, --dry-run            打印将要执行的操作
  -y, --yes                跳过交互确认
      --force              允许降级 / 重装同版本
      --no-restart         替换文件后不自动重启服务
      --auto-rollback      升级失败时自动回滚

回滚
      --rollback [dir]     回滚到指定备份目录；不指定则用最近一次备份
      --restore-db         回滚时同时恢复数据库

  -h, --help               显示帮助

示例
  bash update-1panel.sh --check                                       # 检查最新版本
  bash update-1panel.sh -y                                            # 升到最新稳定版
  bash update-1panel.sh -v v2.4.2 -y                                  # 升到指定版本
  bash update-1panel.sh -m beta -y                                    # 升到 beta 通道
  bash update-1panel.sh -f /tmp/1panel-v2.4.2-linux-amd64.tar.gz -y   # 使用离线包升级
  bash update-1panel.sh --rollback                                    # 回滚到最近备份
```

</details>
