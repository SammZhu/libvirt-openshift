#!/usr/bin/env bash
# diag-ovn-pod2service.sh — 抓 "OVN 早期 pod→service 不通(ENETUNREACH)" 的铁证。
#
# 背景(skill: ovn-pod2service-transient-serviceca-wedge):装机/开机早期,pod 网络 operator
#   (首当其冲 service-ca)偶发 `dial 172.30.0.1:443: connect: network is unreachable` → CrashLoop
#   → serving-cert 连锁堵。推断根因=pod 被调度在 OVN CNI 还没把它 netns 接好的窗口里(缺默认路由)。
#   本脚本在症状出现时抓证,把"推断"升级成"实锤":
#     ① pod 崩溃日志(确认 ENETUNREACH / 172.30.0.1)
#     ② ★pod netns 路由表(缺 default 路由 = 竞态铁证)+ 从 netns 实测连 172.30.0.1
#     ③ ovnkube-node 对该 pod 的 CNI ADD 日志(看有没有报错/漏配)
#
# 用法: ./diag-ovn-pod2service.sh [namespace] [label]
#   默认 openshift-service-ca / app=service-ca。也可查别的 pod 网络 operator。
# 依赖: KUBECONFIG(默认 ~/openshift-install/nest/kubeconfig)+ 节点 SSH key(NODE_SSH_KEY,
#   默认 ~/.ssh/20231118_ed25519,core 用户)。在能同时 oc + SSH 到节点的机器上跑(如 srv-down)。
set -uo pipefail
NS=${1:-openshift-service-ca}
LABEL=${2:-app=service-ca}
KC=${KUBECONFIG:-$HOME/openshift-install/nest/kubeconfig}
KEY=${NODE_SSH_KEY:-$HOME/.ssh/20231118_ed25519}
O="oc --kubeconfig=$KC --request-timeout=15s"
SSHO="-i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"
OUT=$HOME/ovn-diag-$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
log(){ echo "$@" | tee -a "$OUT/summary.txt"; }

log "== OVN pod→service 诊断 $(date -u) =="
POD=$($O -n "$NS" get pods -l "$LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
NODE=$($O -n "$NS" get pods -l "$LABEL" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
PUID=$($O -n "$NS" get pods -l "$LABEL" -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null)
[ -z "$POD" ] && { log "找不到 $NS/$LABEL 的 pod(可能已恢复/被删)"; exit 1; }
NODEIP=$($O get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
log "pod=$POD node=$NODE nodeIP=$NODEIP uid=$PUID"

log "-- ① 崩溃日志(找 ENETUNREACH) --"
{ $O -n "$NS" logs "$POD" --previous --tail=40 2>&1; echo '--- current ---'; $O -n "$NS" logs "$POD" --tail=40 2>&1; } > "$OUT/pod-crash.log"
grep -iE "network is unreachable|172\.30\.0\.1|apiserver connectivity" "$OUT/pod-crash.log" | tail -3 | tee -a "$OUT/summary.txt"

[ -z "$NODEIP" ] && { log "拿不到 nodeIP,跳过节点抓取"; exit 1; }
log "-- ②③ 到节点 $NODEIP 抓 netns 路由 + CNI 日志 --"
# POD/PUID 本地展开后作为位置参数传给远端 root bash;heredoc 单引号避免本地展开
ssh $SSHO core@"$NODEIP" "sudo bash -s '$POD' '$PUID'" > "$OUT/node-capture.txt" 2>&1 <<'REMOTE'
POD="$1"; PUID="$2"
SB=$(crictl pods --name "$POD" -q 2>/dev/null | head -1)
echo "sandbox=$SB"
PID=$(crictl inspectp "$SB" 2>/dev/null | jq -r '.info.pid // empty')
echo "sandbox pid=$PID"
echo "===== ★ pod netns 路由(无 'default' = 竞态铁证:pod 被起早了,OVN CNI 没接完) ====="
if [ -n "$PID" ]; then
  nsenter -t "$PID" -n ip route 2>&1
  echo "-- addr --"; nsenter -t "$PID" -n ip -br addr 2>&1
  echo "===== pod netns 实测连 172.30.0.1 ====="
  nsenter -t "$PID" -n timeout 5 curl -sk -o /dev/null -w 'http=%{http_code} err=%{errormsg}\n' https://172.30.0.1:443/readyz 2>&1
else
  echo "拿不到 sandbox pid(pod 可能不在本节点或已没)"
fi
echo "===== ovnkube-node 对该 pod 的 CNI ADD 日志 ====="
OVN=$(crictl ps --name ovnkube-controller -q 2>/dev/null | head -1)
crictl logs "$OVN" 2>&1 | grep -iE "$POD|$PUID|CNI ADD|ADD finished|configure pod|failed to.*pod" | tail -40
REMOTE

log "→ 证据存于:$OUT (summary.txt / pod-crash.log / node-capture.txt)"
log "★ 看 node-capture.txt 的 'pod netns 路由':若无 default → 证实竞态(pod 起早、CNI 没接完);若有 default 但连 172.30.0.1 仍不通 → 是 OVN 数据面/flow 未就绪(另一种,dataplane lag)。"
