#!/usr/bin/env bash
# rotate-cp-certs.sh — 强制轮转 kube-apiserver serving 证书,重置"安全关机窗口"。
#
# 何时用:计划**连续关机超过当前窗口**(见 make cert-status,本集群初始 ~29 天)时,先重置到 ~30 天。
#   日常几天/一两周的关机不需要——那种 make startup 就能恢复。
# 机制:删 openshift-kube-apiserver 的 serving 证书 secret → kube-apiserver-operator 从签名者
#   重发新证(fresh ~30 天)并**滚动重启 3 master 的 apiserver**(~10-15min,逐个滚,通常无外部中断)。
#   ★只动 serving 证书(brick 的真因:API 得能提供 TLS);etcd(5yr)/kubelet(24h,自恢复)不碰。
# ★请在维护窗口执行;交互确认(非 tty 直接取消,防误触)。
set -uo pipefail
KC=${KUBECONFIG:-$HOME/openshift-install/nest/kubeconfig}
O="oc --kubeconfig=$KC --request-timeout=30s"
NS=openshift-kube-apiserver
SECRETS="external-loadbalancer-serving-certkey internal-loadbalancer-serving-certkey localhost-serving-cert-certkey service-network-serving-certkey"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== 轮转前窗口 =="; bash "$HERE/cert-status.sh" 2>/dev/null | grep -E '安全关机窗口|⚠️' || true
echo ""
echo "将删除并让 operator 重发以下 kube-apiserver serving 证书(会滚动重启 3 master 的 apiserver):"
for s in $SECRETS; do echo "  - $NS/$s"; done
read -r -p "确认继续?(输入 yes 执行,其它取消) " ans || { echo "非交互,取消"; exit 0; }
[ "$ans" = "yes" ] || { echo "已取消"; exit 0; }

REV0=$($O get kubeapiserver cluster -o jsonpath='{.status.latestAvailableRevision}' 2>/dev/null || echo 0)
echo "当前 kube-apiserver revision=$REV0"
for s in $SECRETS; do
  $O -n "$NS" delete secret "$s" >/dev/null 2>&1 && echo "  删了 $s(operator 将重建)" || echo "  $s 删除失败/不存在(跳过)"
done

echo "== 等 kube-apiserver operator 滚动完成(Progressing→False & Available & 新 revision)=="
for i in $(seq 1 80); do
  prog=$($O get co kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null)
  avail=$($O get co kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
  rev=$($O get kubeapiserver cluster -o jsonpath='{.status.latestAvailableRevision}' 2>/dev/null || echo 0)
  echo "[$i] Progressing=${prog:-?} Available=${avail:-?} revision=${rev:-?}"
  if [ "$prog" = "False" ] && [ "$avail" = "True" ] && [ "${rev:-0}" -gt "${REV0:-0}" ]; then
    echo "→ 轮转 + 滚动完成"; break
  fi
  sleep 30
done

echo "== 轮转后窗口 =="; bash "$HERE/cert-status.sh" 2>/dev/null | grep -E '安全关机窗口|⚠️' || true
echo "提示:kubelet/client 证书按自身周期轮转;下次关机后开机仍 make startup 批 CSR 即可。"
