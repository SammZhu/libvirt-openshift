# QUICKSTART

三段式:**① 准备 → ② 预检 → ③ 安装**。

## ① 准备(一次性)

```bash
# 在 rhdemo (driver) 上
cp inventory/hosts.example.yml   inventory/hosts.yml
cp group_vars/all.example.yml    group_vars/all.yml
$EDITOR inventory/hosts.yml group_vars/all.yml     # 填 kvm_host 地址、cluster_name、VIP、worker_count…

# 凭据(不进仓库)
cp ~/Downloads/pull-secret.json ~/.pull-secret.json
export OCM_OFFLINE_TOKEN=…        # 仅 online 需要;offline 跳过

ansible-galaxy collection install -r requirements.yml
```

DNS 必须先就位(否则 install 完 ingress 起不来):
```
api.<cluster>.<base_domain>      A  <api_vip>
*.apps.<cluster>.<base_domain>   A  <ingress_vip>
```

## ② 预检(Day0 就绪性 —— 强烈建议先跑,失败早于装)

```bash
make preflight
# = ansible-playbook -i inventory/hosts.yml playbooks/00-preflight.yml
```

红了就照报错修(资源/DNS/VIP/token),这一步专挡 Day0 常见坑,别跳。

## ③ 安装

```bash
make install          # 串 10→20→30→40→50→60→90
# 或逐 phase:
ansible-playbook -i inventory/hosts.yml playbooks/10-network.yml
# …
ansible-playbook -i inventory/hosts.yml playbooks/90-kubeconfig.yml
```

## 无云自测(hermetic)

```bash
make demo             # check 模式 + mock 变量,不碰真主机/真 API,验 playbook 语法与逻辑走向
```

## 连接性切换

`group_vars/all.yml` 里:`connectivity: online` ↔ `offline`。offline 额外要求本地 assisted-service
已起、release 镜像已 mirror、RHCOS live ISO 本地可用(见 `docs/RUNBOOK.md`)。
