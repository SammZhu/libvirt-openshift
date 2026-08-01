# OPERATIONS —— 运维速查

日常操作命令参考。**都从 srv-down 上跑**(`ssh claude@192.168.1.239`),仓库在 `~/libvirt-openshift`。

> ⚠️ **别直接 `make <target>`**:Makefile 默认 `INV=inventory/hosts.yml` 是错的。用
> `make <target> INV=inventory.yml`,或直接 `ansible-playbook -i inventory.yml playbooks/XX.yml`。
> 本文档下面给的都是可直接复制的完整命令。

---

## 0. 速查表

| 目的 | 命令(在 `~/libvirt-openshift`) |
|---|---|
| 装基础集群(3 master) | `ansible-playbook -i inventory.yml site.yml` |
| Day2 加 worker | `ansible-playbook -i inventory.yml playbooks/70-day2-workers.yml` |
| Day2 存储+CNV(LVMS+虚拟化) | `ansible-playbook -i inventory.yml playbooks/71-day2-storage-cnv.yml` |
| Day2 ODF(Ceph/RWX) | `ansible-playbook -i inventory.yml playbooks/72-day2-odf.yml` |
| **优雅关机**(含关物理机) | `ansible-playbook -i inventory.yml playbooks/97-shutdown.yml -e shutdown_hosts=true` |
| **开机恢复** | `ansible-playbook -i inventory.yml playbooks/98-startup.yml` |
| 拆集群(销毁) | `ansible-playbook -i inventory.yml playbooks/99-teardown.yml` |
| 证书安全关机窗口 | `make cert-status`(= `bash tools/cert-status.sh`) |
| 强制轮转控制面证书(重置窗口) | `make rotate-cp-certs` |
| 抓 OVN pod→service 铁证 | `make diag-ovn` |
| 无云语法自检 | `make demo` |

---

## 1. 访问集群

```bash
export KUBECONFIG=~/openshift-install/nest/kubeconfig
oc get nodes
```
- **Console**：https://console-openshift-console.apps.nest.virt.lab
- **用户**：`kubeadmin`　**密码**：`~/openshift-install/nest/kubeadmin-password`
- **API VIP**：`https://192.168.1.200:6443`（`api.nest.virt.lab`）

---

## 2. 关机 / 开机

两台物理机已启用 **`libvirt-guests`**(关机时先优雅 ACPI 关 VM),所以下面两种关机都安全。

### 关机 —— 方式一(推荐,最完整)
```bash
cd ~/libvirt-openshift && ansible-playbook -i inventory.yml playbooks/97-shutdown.yml -e shutdown_hosts=true
```
cert 窗口提醒 → **etcd 备份** → worker 先→master 后 ACPI 优雅关 → 等下电 → 关两台物理机。
（去掉 `-e shutdown_hosts=true` 则只关 VM、不关物理机；`-e etcd_backup=false` 跳备份。）

### 关机 —— 方式二(最简单,直接关物理机)
```bash
cd ~/libvirt-openshift && ansible kvm_host -i inventory.yml -b -m shell -a "shutdown -h +1"
```
或登到每台机 `poweroff` / `shutdown -h now` / `halt -p`。libvirt-guests 会先优雅关 VM。
省了 etcd 备份和关机顺序,但每台 VM 都干净停,够用。

### 开机
1. 上电两台物理机(rhdemo 192.168.1.152、rhel10 192.168.1.137)
2. ```bash
   cd ~/libvirt-openshift && ansible-playbook -i inventory.yml playbooks/98-startup.yml
   ```
自动:启动 VM → 等 API → 循环批 CSR(修关机期过期的 kubelet 证书)→ 等 5 节点 Ready →
报安全关机窗口 → **窗口 <5 天则自动轮转控制面证书**(`rotate_below_days` 可配,`0` 关)。

> VM 不自启;`98-startup` 负责 `virsh start`。若节点长期 NotReady,`oc get csr -o name | xargs oc adm certificate approve`。

---

## 3. 证书 / 安全关机窗口

**两层证书**:①kubelet/oauth **24h** 轮转层——关机过期,**开机批 CSR 自恢复**,不 brick;
②kube-apiserver serving **~30 天**——**连续关机越过它才真 brick**(API 起不来);etcd 5 年、admin kubeconfig 10 年。
**安全关机窗口 = 最早控制面 serving 证书到期(初装约 29 天)。**

```bash
make cert-status                 # 报窗口:还能安全关多少天
make rotate-cp-certs             # 计划连续关机 >窗口 时,先重置窗口到 ~30 天(会滚动重启控制面)
```
- 开机 <5 天会自动轮转(见 §2 开机)。
- 判 brick vs 可恢复:开机后 **API 起得来 = 可恢复(批 CSR)**;起不来 = 控制面证书过期真 brick。

---

## 4. 健康检查

```bash
export KUBECONFIG=~/openshift-install/nest/kubeconfig
oc get nodes                                                    # 5 节点 Ready
oc get co | grep -vE 'True .* False .* False'                   # 有异常的 CO
oc get pods -n openshift-etcd | grep etcd-master                # etcd 3 成员
oc -n openshift-storage get cephcluster -o jsonpath='{.items[0].status.ceph.health}'   # HEALTH_OK
oc -n openshift-cnv get hyperconverged kubevirt-hyperconverged -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'  # True
oc get sc                                                       # 存储类:lvms-vg1 / ceph-rbd / ceph-rbd-virtualization / cephfs(RWX)
```

---

## 5. 常见故障恢复

### ODF OSD 崩溃 `OSD id X != my id Y`(unclean 关机后高频)
rook 本地盘 OSD 的 deployment 烤的 id 与盘元数据错位。**删 pod / 重启 operator 无效**,要删 deployment 让 rook 按盘重建:
```bash
oc -n openshift-storage delete deployment -l app=rook-ceph-osd
oc -n openshift-storage delete pod -l app=rook-ceph-operator
# 等 3 OSD Running + Ceph HEALTH_OK(~5-7min)
```
> 根治:host 已启用 libvirt-guests，优雅关机就不会再触发。

### 装机/开机卡 66%,service-ca CrashLoop(`dial 172.30.0.1:443: network is unreachable`)
OVN 早期 pod→service 间歇 transient。抓证 + nudge:
```bash
make diag-ovn                                                  # 抓 pod netns 路由 + CNI 日志(铁证)
oc -n openshift-service-ca delete pod -l app=service-ca        # pod 网络已通时 nudge 逼重试
```
重启节点也能清掉 transient。

### 节点 NotReady + Pending CSR(关机期证书过期)
```bash
oc get csr -o name | xargs oc adm certificate approve
```

### mon/osd Pending(装 ODF 时,manageNodes:false 缺标签)
```bash
oc label node -l node-role.kubernetes.io/master cluster.ocs.openshift.io/openshift-storage=""
```

---

## 6. 重要提醒(Gotchas)

- **从 srv-down 跑**(`claude@192.168.1.239`),仓库 `~/libvirt-openshift`;真配置 `group_vars/all.yml`、`inventory.yml`、`state.yml` 是 gitignore。
- **节点 SSH**:`ssh -i ~/.ssh/20231118_ed25519 core@192.168.1.21x`(masters .210/.211/.212,workers .213/.214)。
- **rhel10 需 `become: true`**(virsh 无 polkit);**开机后 rhel10 SSH 可能有 pam_nologin 延迟**(等 boot 完再跑 startup)。
- **master 8c/24G 上 ODF+CNV 资源偏紧**,OSD 易被扰动 → id-mismatch(见 §5)。
- **etcd 备份**在 `master-0:/home/core/etcd-backup-*`。
- 全生命周期:`install → add-workers → storage-cnv → odf → shutdown ⇄ startup → teardown`。
