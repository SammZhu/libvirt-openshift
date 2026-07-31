INV ?= inventory/hosts.yml
PB  = ansible-playbook -i $(INV)

.PHONY: help preflight network cluster iso vms wait install-ocp kubeconfig install add-workers storage-cnv odf startup diag-ovn cert-status rotate-cp-certs teardown demo lint

help:
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/ —/' | sort

preflight:   ## Day0 就绪性预检
	$(PB) playbooks/00-preflight.yml
network:     ## libvirt 网络/DHCP/VIP
	$(PB) playbooks/10-network.yml
cluster:     ## 建 assisted cluster + infra-env
	$(PB) playbooks/20-assisted-cluster.yml
iso:         ## 取 discovery ISO
	$(PB) playbooks/30-discovery-iso.yml
vms:         ## virt-install master+worker
	$(PB) playbooks/40-vms.yml
wait:        ## 轮询 host 注册 + 校验
	$(PB) playbooks/50-wait-hosts.yml
install-ocp: ## 定角色 + 触发安装
	$(PB) playbooks/60-install.yml
kubeconfig:  ## 取 kubeconfig
	$(PB) playbooks/90-kubeconfig.yml

install: network cluster iso vms wait install-ocp kubeconfig  ## 全流程(不含 preflight)。control_plane_only=true 时只装 3 master;worker 走 Day2

add-workers: ## Day2 加 worker(基础集群 installed 后;worker host 需开机)
	$(PB) playbooks/70-day2-workers.yml

storage-cnv: ## Day2 LVMS(worker 本地存储)+ CNV(OpenShift Virtualization)
	$(PB) playbooks/71-day2-storage-cnv.yml

odf:         ## Day2 ODF(Ceph,RWX;master OSD 裸盘 + LSO + StorageCluster)
	$(PB) playbooks/72-day2-odf.yml

startup:     ## 开机/关机恢复:启动 VM + 批 CSR(证书过期)+ 等节点 Ready
	$(PB) playbooks/98-startup.yml

diag-ovn:    ## 抓 OVN pod→service 不通(service-ca ENETUNREACH)铁证
	bash tools/diag-ovn-pod2service.sh

cert-status: ## 报告证书到期 + 算"安全关机窗口"(brick 前多少天)
	bash tools/cert-status.sh

rotate-cp-certs: ## 强制轮转 kube-apiserver serving 证书,重置安全关机窗口(会滚动重启控制面)
	bash tools/rotate-cp-certs.sh

teardown:    ## 拆集群:销毁 VM+盘 + 删 assisted cluster + 清 state
	$(PB) playbooks/99-teardown.yml

demo:        ## 无云 hermetic:全 playbook 语法校验,不碰真主机/真 API/凭据
	ansible-playbook --syntax-check site.yml
	ansible-playbook --syntax-check playbooks/70-day2-workers.yml
	ansible-playbook --syntax-check playbooks/71-day2-storage-cnv.yml
	ansible-playbook --syntax-check playbooks/72-day2-odf.yml
	ansible-playbook --syntax-check playbooks/98-startup.yml
	ansible-playbook --syntax-check playbooks/99-teardown.yml
	@echo "✓ syntax OK — all phases parse"

lint:        ## ansible-lint 门禁
	ansible-lint
