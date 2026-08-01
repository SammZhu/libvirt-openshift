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

## 拓扑（全 VM,双 KVM host,终态 = OpenShift Virtualization / CNV 实验环境）

```
  RHEL8 (Ansible 控制节点)     rhdemo RHEL9 32c/251G (常开)       rhel10 RHEL10 80c/125G (按需开,省电)
  ├─ git clone 本工程     ─SSH─► ├─ master-0/1/2 (VM,可调度,兼 ODF)  ├─ worker-0/1 (VM, host-passthrough)
  └─ ansible-playbook          │   └─ 各挂 1 块裸 NVMe → ODF 3-OSD  │   └─ 嵌套跑 CNV 虚机
     (assisted API 编排)        │  控制面 + 存储都在此              │  数据盘取自 nvme0 1.8T → 本地 LVMS
                                └─ 关 rhel10 → 集群+ODF 全在,只 CNV 停
  网络: machine=192.168.1(1G, API/VIP) │ 存储+迁移=10.10(10G 线速, br-ovs)
  VIP: API/Ingress keepalived(多节点 assisted 自带,无需外部 LB)
```

- **RHEL8**(= srv-down)—— Ansible 客户端,clone 工程跑 playbook,不装节点。
- **rhdemo RHEL9** —— KVM host(常开):3 个可调度 master VM,兼 ODF 存储节点(3 块裸 NVMe 各做 1 OSD)。控制面 + 存储都在此,关 rhel10 也不受影响。
- **rhel10 RHEL10** —— KVM host(按需开):2 个 worker VM,`--cpu host-passthrough` 透传 vmx → **嵌套跑 CNV**;nvme0(1.8T)做节点本地 LVMS。

> 全部 OpenShift 节点都是 VM(无裸金属节点),两台都是 libvirt host。所有节点在**同一 assisted infra-env**注册。
> **嵌套 CNV = Red Hat 仅支持 dev/test(非生产)**,性能有损耗——本 lab 用于学习/沉淀 Skill,可接受。
> 装完 Day2 落 **ODF operator**(rhdemo 三盘)+ **CNV operator**(rhel10 worker)+ **LVMS**(rhel10 本地盘)。
> 双轴仍在:`installation_method`(assisted/ABI)× `connectivity`(online/offline)。

## Phase 编排

| Phase | Playbook | 做什么 | 状态 |
|------|----------|--------|:--:|
| 00 | `playbooks/00-preflight.yml` | **Day0 就绪性**:虚拟化/嵌套虚拟化、libvirt(virsh)、真 pool、容量、裸盘、DNS/VIP、API/凭据 | ✅ 硬件 gate live 验 |
| 10 | `playbooks/10-network.yml` | 每台 host 网络就绪:machine=macvtap(默认,安全)/bridge(可选);storage=br-ovs;可选统一 MTU | ✅ 已实现 |
| 20 | `playbooks/20-assisted-cluster.yml` | 建 cluster + infra-env(v2 REST;VIP/网络/NTP;幂等 state) | ✅ live 验 |
| 25 | `playbooks/25-static-network.yml` | 下发每节点静态网络(NMState:eth0 machine / eth1 10G storage)到 infra-env | ✅ 已实现 |
| 30 | `playbooks/30-discovery-iso.yml` | 取 discovery ISO 到各 host pool | ✅ live 验 |
| 40 | `playbooks/40-vms.yml` | `virt-install` master×3(+OSD 裸盘直通)/ worker×N(host-passthrough+LVMS 盘),双网卡,从 ISO 引导 | ✅ 已实现 |
| 50 | `playbooks/50-wait-hosts.yml` | 等注册 + 按 MAC 匹配 nodes 设角色/主机名 + 等 ready | ✅ 已实现 |
| 60 | `playbooks/60-install.yml` | 触发安装 + 轮询到 installed | ✅ 已实现 |
| 90 | `playbooks/90-kubeconfig.yml` | 取 kubeconfig / kubeadmin / console | ✅ 已实现 |

`site.yml` 按顺序串起来。

## 凭据(铁律:只走 env / vault,永不进仓库)

| 用途 | 来源 |
|------|------|
| SaaS token(online) | `export OCM_OFFLINE_TOKEN=…`(console.redhat.com → API tokens) |
| pull secret | `~/.pull-secret.json`(已在 `.gitignore`) |
| SSH 公钥 | `~/.ssh/id_rsa.pub` |

## 快速开始

见 [QUICKSTART.md](QUICKSTART.md)。最短路径:`make preflight` → 逐 phase → `make install`。

## 运维

日常操作(关机/开机、证书安全关机窗口、Day2 存储/CNV/ODF、故障恢复)见 **[docs/OPERATIONS.md](docs/OPERATIONS.md)** 速查。
全生命周期:`install → add-workers → storage-cnv → odf → shutdown ⇄ startup → teardown`。
