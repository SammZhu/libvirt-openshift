#!/usr/bin/env bash
# cert-status.sh — 报告集群证书到期,算出"安全关机窗口"。
#
# 两层(skill 层面区分):
#   ① 24h 轮转层(kubelet / oauth authenticator 等):过期后**开机可自恢复**
#      (make startup 批 CSR + operator 重发),不构成 brick。
#   ② 控制面 serving/signer 证书(kube-apiserver serving、csr-signer 等,~30 天):
#      **连续关机越过它才真 brick**(API 起不来、批 CSR 都够不着)。etcd 证书通常 5 年,非软肋。
#   安全关机窗口 = 最早的"非 24h"证书到期(取 >2 天外的最早一个,24h 层都在 2 天内)。
#
# 用法: ./cert-status.sh    (需 KUBECONFIG,默认 ~/openshift-install/nest/kubeconfig)
set -uo pipefail
KC=${KUBECONFIG:-$HOME/openshift-install/nest/kubeconfig}
O="oc --kubeconfig=$KC --request-timeout=20s"
NOW=$(date -u +%s)

ALL=$($O get secrets -A -o json 2>/dev/null | jq -r '.items[]|select(.metadata.annotations["auth.openshift.io/certificate-not-after"]!=null)|"\(.metadata.annotations["auth.openshift.io/certificate-not-after"]) \(.metadata.namespace)/\(.metadata.name)"' | sort)
[ -z "$ALL" ] && { echo "拿不到证书信息(集群可用? KUBECONFIG=$KC)"; exit 1; }

echo "== 证书状态  $(date -u) =="
echo "-- 最早 5 个(前几个通常是 24h 轮转层,过期开机自恢复)--"
echo "$ALL" | head -5

# brick 窗口:最早的"到期在 2 天之外"的证书(24h 层都在 2 天内)
CUT=$((NOW + 2*86400))
BRICKLINE=$(echo "$ALL" | while read -r t rest; do
  ts=$(date -u -d "$t" +%s 2>/dev/null) || continue
  [ "$ts" -gt "$CUT" ] && echo "$ts $t $rest"
done | sort -n | head -1)

if [ -n "$BRICKLINE" ]; then
  BTS=$(echo "$BRICKLINE" | awk '{print $1}')
  BWHEN=$(echo "$BRICKLINE" | awk '{print $2}')
  BNAME=$(echo "$BRICKLINE" | awk '{print $3}')
  DAYS=$(( (BTS - NOW) / 86400 ))
  echo ""
  echo "★ 安全关机窗口 ≈ ${DAYS} 天(最早控制面证书 ${BNAME} 到期 ${BWHEN})"
  echo "  · 早于该日开机 → 干净恢复(24h 证书 make startup 批 CSR 自愈)"
  echo "  · 晚于该日 → 控制面证书过期 → API 起不来真 brick,需强制轮转/重装"
  if [ "$DAYS" -lt 7 ]; then
    echo "  ⚠️ 窗口 <7 天!长关机前先重置窗口:让集群跑到临近到期由 operator 自动轮转,"
    echo "     或强制轮转(delete 对应 serving 证书 secret 让 operator 重发,会滚动重启控制面)。"
  fi
else
  echo "(未找到 >2 天外的控制面证书,数据异常?)"
fi
