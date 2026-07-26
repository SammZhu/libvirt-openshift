# RUNBOOK

## 前置(both paths)

- **DNS** 预置(否则 install 完 ingress 不起):
  ```
  api.<cluster>.<base_domain>     A  <api_vip>
  *.apps.<cluster>.<base_domain>  A  <ingress_vip>
  ```
- **pull secret** → `~/.pull-secret.json`;**SSH 公钥** → `~/.ssh/id_rsa.pub`
- KVM host:libvirtd 起、virt-install/qemu-img/virsh 在、pool 有空间;若 host 本身是 VM,**开嵌套虚拟化**
- VIP(api/ingress)当前**未被占用**,且落在 `machine_network_cidr` 内

`make preflight` 会逐条校验以上,红了照报错修。

## Online(connectivity: online)

SaaS Assisted API,connected 环境:
```bash
export OCM_OFFLINE_TOKEN=…                 # console.redhat.com → API tokens
# 或写入 offline_token_file(默认 ~/.openshift/offline-token)
make preflight && make install
```
token 只在内存(assisted_token.yml 现取现用,~15min TTL),不落仓库。

## Offline(connectivity: offline,air-gap)

在 KVM host 上先起本地 assisted-service + image-service(podman),并把 release 镜像 mirror 进本地 registry:
1. 本地 `assisted-service` 暴露 `:8090`(`assisted_onprem_url` 指向它)——无需 offline token。
2. `oc-mirror` / `oc adm release mirror` 把 `openshift_version` 对应 release 拉进 `local_registry`。
3. RHCOS live ISO 落到 `rhcos_live_iso_path`。
4. `connectivity: offline` 后 `make preflight && make install`,下游与 online 完全一致。

> online/offline 只差 `assisted_base_url` + 是否带 Bearer;`tasks/assisted_base.yml` 是唯一的开关点。

## 排障

- 任一 phase 失败,`callback_plugins/surface_errors.py` 会打红框 stderr/rc,不用翻 JSON。
- 日志滚存 `logs/ansible.log`。
- 状态在 `state.yml`(cluster_id/infra_env_id/…),重跑幂等;teardown 见 `playbooks/99-teardown.yml`(待实现)。

## Day0 常见坑(preflight 已挡,列此备查)

| 症状 | 根因 | preflight 检查 |
|------|------|----------------|
| install 到 100% 但 console/ingress 打不开 | 缺 `*.apps` 通配 DNS | api/*.apps → VIP 断言 |
| bootstrap 卡住 / VIP 不通 | api/ingress VIP 已被占用(IP 冲突) | VIP ping-free 断言 |
| host 校验 "insufficient CPU/insufficient hardware" | host 是 VM 但嵌套虚拟化没开 | nested-virt 探测告警 |
| Assisted host 校验 disk too small | 安装盘 < 100 GB | pool 容量 + disk_gib 断言 |
| 401 / token 失效 mid-install | offline token 过期 | online 预检即 mint token |
| CreateStack/version 报找不到版本 | `openshift_version` 用了 channel 形(X.Y) | 版本在 Assisted 列表断言 |
