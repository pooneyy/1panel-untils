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
