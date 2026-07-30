INV ?= inventory/hosts.yml
PB  = ansible-playbook -i $(INV)

.PHONY: help preflight network cluster iso vms wait install-ocp kubeconfig install teardown demo lint

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

teardown:    ## 拆集群:销毁 VM+盘 + 删 assisted cluster + 清 state
	$(PB) playbooks/99-teardown.yml

demo:        ## 无云 hermetic:全 playbook 语法校验,不碰真主机/真 API/凭据
	ansible-playbook --syntax-check site.yml
	ansible-playbook --syntax-check playbooks/99-teardown.yml
	@echo "✓ syntax OK — all phases parse"

lint:        ## ansible-lint 门禁
	ansible-lint
