#!/usr/bin/env bash
# cert-status.sh — 报告集群证书到期,算出"安全关机窗口"。
#
# 两层(skill 层面区分):
#   ① 24h 轮转层(kubelet / oauth authenticator 等):过期后**开机可自恢复**
#      (make startup 批 CSR + operator 重发),不构成 brick。
#   ② 控制面 serving/signer 证书(kube-apiserver serving、csr-signer 等,~30 天):
#      **连续关机越过它才真 brick**(API 起不来、批 CSR 都够不着)。etcd 证书通常 5 年,非软肋。
#   安全关机窗口 = 最早的 kube-apiserver/etcd 证书到期(只有这两处会让 API 起不来;
#   其它 client 证书开机后 operator 自动重签,不计入)。
#
# 用法: ./cert-status.sh    (需 KUBECONFIG,默认 ~/openshift-install/nest/kubeconfig)
set -uo pipefail
KC=${KUBECONFIG:-$HOME/openshift-install/nest/kubeconfig}
O="oc --kubeconfig=$KC --request-timeout=20s"
NOW=$(date -u +%s)
# 缓存最早控制面证书到期日:每次成功读到 live 证书就刷新它。集群关机时晨报读它、按今天本地
# 重算剩余天数(到期日在关机期间不变)。故只要开机跑过一次(如 make startup 末尾)就自愈重建。
CACHE="${OCP_CERT_CACHE:-$HOME/.cache/ocp-cert-expiry}"

ALL=$($O get secrets -A -o json 2>/dev/null | jq -r '.items[]|select(.metadata.annotations["auth.openshift.io/certificate-not-after"]!=null)|"\(.metadata.annotations["auth.openshift.io/certificate-not-after"]) \(.metadata.namespace)/\(.metadata.name)"' | sort)
[ -z "$ALL" ] && { echo "拿不到证书信息(集群可用? KUBECONFIG=$KC)"; exit 1; }

echo "== 证书状态  $(date -u) =="
echo "-- 最早 5 个(前几个通常是 24h 轮转层,过期开机自恢复)--"
echo "$ALL" | head -5

# brick 窗口只看「决定 API 能不能起来」的证书:openshift-kube-apiserver* 与 openshift-etcd*。
# 这两处过期 → API 起不来、连 CSR 都够不着 → 真 brick,只能强制轮转/重装。
# 其余(monitoring/oauth/cnv 的 client 证书、kube-controller-manager/csr-signer 等)开机后
# 由各自 operator 自动重签(csr-signer 由 2029 的 csr-signer-signer 重生),过期只造成短暂
# 功能异常,不阻止 API 启动,故不计入窗口、只作提示。
# 教训(2026-08-25):曾把 monitoring/oauth 的 client 证书当窗口 → 误报「剩 5 天」,
# 而彼时 kube-apiserver serving 其实还有 30 天。那批 client 证书是在 csr-signer 轮转前
# 6 分钟签发的,被旧 signer 到期日封顶;删掉让 operator 重签即跟上新 signer。
BRICK_RE='^openshift-(kube-apiserver|etcd)'
CUT=$((NOW + 2*86400))
pick_earliest() {   # stdin: "<notAfter> <ns/name>";stdout: "<epoch> <notAfter> <ns/name>"
  while read -r t rest; do
    [ -n "$t" ] || continue
    ts=$(date -u -d "$t" +%s 2>/dev/null) || continue
    [ "$ts" -gt "$CUT" ] && echo "$ts $t $rest"
  done | sort -n | head -1
}
BRICKLINE=$(echo "$ALL" | awk -v re="$BRICK_RE" '$2 ~ re' | pick_earliest)
OTHERLINE=$(echo "$ALL" | awk -v re="$BRICK_RE" '$2 !~ re' | pick_earliest)

if [ -n "$BRICKLINE" ]; then
  BTS=$(echo "$BRICKLINE" | awk '{print $1}')
  BWHEN=$(echo "$BRICKLINE" | awk '{print $2}')
  BNAME=$(echo "$BRICKLINE" | awk '{print $3}')
  DAYS=$(( (BTS - NOW) / 86400 ))
  # 刷新缓存(供晨报在集群关机时离线重算;开机跑一次即自愈重建)
  mkdir -p "$(dirname "$CACHE")" 2>/dev/null && printf '%s\n' "$BWHEN" > "$CACHE" 2>/dev/null
  echo ""
  echo "★ 安全关机窗口 ≈ ${DAYS} 天(最早控制面证书 ${BNAME} 到期 ${BWHEN})"
  echo "  · 早于该日开机 → 干净恢复(24h 证书 make startup 批 CSR 自愈)"
  echo "  · 晚于该日 → 控制面证书过期 → API 起不来真 brick,需强制轮转/重装"
  if [ -n "$OTHERLINE" ]; then
    echo "  (参考:非 brick 类最早到期 $(echo "$OTHERLINE" | awk '{print $2" "$3}') —— 开机后 operator 自动重签,不计入窗口)"
  fi
  if [ "$DAYS" -lt 7 ]; then
    echo "  ⚠️ 窗口 <7 天!长关机前先重置窗口:让集群跑到临近到期由 operator 自动轮转,"
    echo "     或强制轮转(delete 对应 serving 证书 secret 让 operator 重发,会滚动重启控制面)。"
  fi
else
  echo "(未找到 >2 天外的控制面证书,数据异常?)"
fi
