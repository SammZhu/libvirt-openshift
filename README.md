# libvirt-openshift

用 **Ansible** 把 OpenShift(**3 control-plane + N worker**)装到 **RHEL host 上的 libvirt/KVM VM** 里。
名字按**底座**取(libvirt),不绑安装方法——安装方法是可切换的一轴。

**两轴模型:**

- **`installation_method`**(装法) —— `assisted`(assisted-service REST 引导)/ `agent-based`(ABI,离线自足,生成 agent ISO,无需 REST;走 `site-agent.yml`,借鉴 `alibaba-openshift`)。
- **`connectivity`**(连接性,仅 `assisted` 用) —— `online` = SaaS `api.openshift.com`(`OCM_OFFLINE_TOKEN` 换 access token)/ `offline` = 本地 `assisted-service`(podman,air-gap,release 本地 mirror)。

三条路(assisted-online / assisted-offline / ABI)走完 **discovery/agent ISO → VM 起盘 → host 注册 → 校验 → install** 是**共享**的下游。

> 当前 **assisted 路径优先实现**(Phase 00 preflight 已落地);ABI 走 `site-agent.yml`,与 `alibaba-openshift`
> 的 `installation_method: Assisted|Agent-based` 同构。
>
> 姊妹项目 `alibaba-openshift` 装在阿里云 ECS;本项目底座换成 host 上的 libvirt VM,沿用其
> phase 编号 playbook、`surface_errors` 回调、`run_cli`、`installation_method` 开关、ansible-lint 门禁、
> `make demo` + QUICKSTART 三段式约定。

## 拓扑（3 台机器,终态 = OpenShift Virtualization / CNV 实验环境）

```
  RHEL8 (Ansible 控制节点)          RHEL9 rhdemo (KVM host)              RHEL10 OpenShiftV (物理机)
  ├─ git clone 本工程         ─SSH─► ├─ libvirt: ocp-net                  ├─ 裸金属 worker,加入同集群
  └─ ansible-playbook              │  ├─ master-0/1/2 (VM,control)      │  ├─ 本地裸盘 → ODF 存储
     (assisted API 调用/编排)      │  └─ worker VM ×n (可选)             │  └─ 原生虚拟化 → 跑 CNV 虚机
                                    │  ★nested virt 必开(VM 节点要跑 CNV)  DNS: api/*.apps → VIP
                                    └─ 从 discovery ISO 引导注册           物理机走虚拟介质/USB/PXE 引导注册
   API VIP / Ingress VIP (keepalived,多节点 assisted 自带,无需外部 LB)
```

- **RHEL8** —— Ansible 客户端(= srv-down),clone 本工程、跑 playbook;不装任何节点。
- **RHEL9 `rhdemo`** —— libvirt KVM host,承载 OpenShift **control plane(3 VM)** +（可选)VM worker。VM 节点要跑 CNV,所以 **nested virt 必开**(不再是"可选告警")。
- **RHEL10 `OpenShiftV`** —— **物理裸金属 worker**,加入同一集群:本地裸盘供 **ODF** 存储、原生虚拟化承载 **OpenShift Virtualization(CNV)** 虚机。

> 混合节点(VM + 物理机)在**同一个 assisted infra-env** 里注册:VM 由 `virt-install` 从 discovery ISO 引导,物理机由虚拟介质/USB/PXE 从同一 ISO 引导。装完集群后,Day2 落 **ODF operator + CNV operator** 构成虚拟化环境。

## Phase 编排

| Phase | Playbook | 做什么 |
|------|----------|--------|
| 00 | `playbooks/00-preflight.yml` | **Day0 就绪性**:虚拟化/嵌套虚拟化、libvirt、资源、DNS/VIP、API/凭据可达 |
| 10 | `playbooks/10-network.yml` | libvirt 网络(NAT/bridge)、DHCP、VIP 预留 |
| 20 | `playbooks/20-assisted-cluster.yml` | 建 cluster + infra-env(online 走 SaaS / offline 走本地 svc) |
| 30 | `playbooks/30-discovery-iso.yml` | 取 discovery ISO 到 host |
| 40 | `playbooks/40-vms.yml` | `virt-install` 起 master×3 + worker×N,从 ISO 引导 |
| 50 | `playbooks/50-wait-hosts.yml` | 轮询 host 注册 + assisted 校验通过 |
| 60 | `playbooks/60-install.yml` | 定角色、触发安装、轮询进度 |
| 90 | `playbooks/90-kubeconfig.yml` | 取 kubeconfig / kubeadmin 密码 |

`site.yml` 按顺序串起来。

## 凭据(铁律:只走 env / vault,永不进仓库)

| 用途 | 来源 |
|------|------|
| SaaS token(online) | `export OCM_OFFLINE_TOKEN=…`(console.redhat.com → API tokens) |
| pull secret | `~/.pull-secret.json`(已在 `.gitignore`) |
| SSH 公钥 | `~/.ssh/id_rsa.pub` |

## 快速开始

见 [QUICKSTART.md](QUICKSTART.md)。最短路径:`make preflight` → 逐 phase → `make install`。
