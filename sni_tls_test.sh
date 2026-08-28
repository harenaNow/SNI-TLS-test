#!/usr/bin/env bash

VERSION="1.2.0"

TIMEOUT=1
CONC=8
ROUNDS=3
TOPN=0
DOMAINS_FILE=""
TLS13=1
EXTRA_DOMAINS=()

DEFAULT_DOMAINS="b.6sc.co lpcdn.lpsnmedia.net j.6sc.co xp.apple.com s.go-mpulse.net www.nvidia.com statici.icloud.com sisu.xboxlive.com www.wowt.com fpinit.itunes.apple.com c.s-microsoft.com www.icloud.com r.bing.com cdn.userway.org ts2.tc.mm.bing.net a0.awsstatic.com azure.microsoft.com amp-api-edge.apps.apple.com j.6sc.co www.xilinx.com apps.mzstatic.com devblogs.microsoft.com snap.licdn.com s0.awsstatic.com ipv6.6sc.co th.bing.com ts4.tc.mm.bing.net drivers.amd.com go.microsoft.com b.6sc.co lpcdn.lpsnmedia.net amd.com s.mp.marsflag.com th.bing.com d2c.aws.amazon.com ts1.tc.mm.bing.net t0.m.awsstatic.com sisu.xboxlive.com fpinit.itunes.apple.com digitalassets.tesla.com t0.m.awsstatic.com www.oracle.com downloadmirror.intel.com iosapps.itunes.apple.com cua-chat-ui.tesla.com mscom.demdex.net www.xbox.com i7158c100-ds-aksb-a.akamaihd.net amd.com intelcorp.scene7.com j.6sc.co www.amd.com gray.video-player.arcpublishing.com c.6sc.co s0.awsstatic.com s.mp.marsflag.com ts3.tc.mm.bing.net www.xilinx.com ce.mf.marsflag.com drivers.amd.com www.tesla.com www.apple.com www.microsoft.com apps.apple.com www.cartoonbrew.com shin-ei-animation.jp www.ritao.co ani-com.hk"

die() { printf '错误: %s\n' "$*" >&2; exit 1; }

usage() {
cat <<EOF
Reality 协议域名优选脚本 v$VERSION

用法:
  $0 [选项] [域名...]
  bash -c "\$(curl -sSL <脚本URL>)" -- [选项] [域名...]
  curl -sSL <脚本URL> | bash -s -- [选项] [域名...]

选项:
  -t 秒      单次 TLS 握手超时秒数 (默认: 1)
  -c N       并发测试数 (默认: 8)
  -r N       每个域名测试次数, 取平均值 (默认: 3)
  -n N       只显示最快的 N 个结果
  -f 文件    从文件读取域名 (每行一个, 支持注释, 提供时替代默认列表)
  --no-tls13 关闭 TLS 1.3 支持检测 (默认开启, Reality 要求目标支持 TLS 1.3)
  -h, --help     显示本帮助
  -V, --version  显示版本

说明:
  不带域名参数时使用内置常用网站列表 (自动去重)。
  默认检测每个域名的 TLS 1.3 支持情况, --no-tls13 可关闭。
  每个域名默认测试 3 次取平均值, 全部成功的列为稳定域名,
  部分失败的单独标出 (格式: 平均延迟 成功次数/总次数)。
  结果按 TLS 握手延迟升序排列, 延迟越低越适合作为 Reality SNI。
  测量的是完整 TCP+TLS 握手耗时 (与 openssl s_client 一致)。

依赖: bash openssl awk sed grep sort
      Alpine 系统请先执行: apk add bash openssl
EOF
}

command -v openssl >/dev/null 2>&1 || die "未找到 openssl"
command -v awk     >/dev/null 2>&1 || die "未找到 awk"
command -v sed     >/dev/null 2>&1 || die "未找到 sed"
command -v grep    >/dev/null 2>&1 || die "未找到 grep"

while [ $# -gt 0 ]; do
  case "$1" in
    -t) [ $# -ge 2 ] || die "-t 需要参数"; TIMEOUT="$2"; shift 2 ;;
    -c) [ $# -ge 2 ] || die "-c 需要参数"; CONC="$2"; shift 2 ;;
    -r) [ $# -ge 2 ] || die "-r 需要参数"; ROUNDS="$2"; shift 2 ;;
    -n) [ $# -ge 2 ] || die "-n 需要参数"; TOPN="$2"; shift 2 ;;
    -f) [ $# -ge 2 ] || die "-f 需要参数"; DOMAINS_FILE="$2"; shift 2 ;;
    --tls13) TLS13=1; shift ;;
    --no-tls13) TLS13=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -V|--version) printf 'sni_tls_test.sh %s\n' "$VERSION"; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do EXTRA_DOMAINS+=("$1"); shift; done ;;
    -*) die "未知选项: $1 (用 -h 查看帮助)" ;;
    *) EXTRA_DOMAINS+=("$1"); shift ;;
  esac
done

case "$TIMEOUT" in ''|*[!0-9]*) die "-t 必须为正整数秒" ;; esac
[ "$TIMEOUT" -ge 1 ] || die "-t 必须 >= 1"
case "$CONC" in ''|*[!0-9]*) die "-c 必须为正整数" ;; esac
[ "$CONC" -ge 1 ] || die "-c 必须 >= 1"
case "$ROUNDS" in ''|*[!0-9]*) die "-r 必须为正整数" ;; esac
[ "$ROUNDS" -ge 1 ] || die "-r 必须 >= 1"
case "$TOPN" in ''|*[!0-9]*) die "-n 必须为非负整数" ;; esac

if [ -n "$DOMAINS_FILE" ]; then
  [ -r "$DOMAINS_FILE" ] || die "无法读取文件: $DOMAINS_FILE"
  input_list=$(grep -vE '^[[:space:]]*(#|$)' -- "$DOMAINS_FILE")
elif [ "${#EXTRA_DOMAINS[@]}" -gt 0 ]; then
  input_list="${EXTRA_DOMAINS[*]}"
else
  input_list="$DEFAULT_DOMAINS"
fi

DOMAINS=$(printf '%s\n' "$input_list" | tr ' \t' '\n\n' | tr -d '\r' | tr 'A-Z' 'a-z' | \
  sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#/.*$##' -e 's/:.*$//' | \
  awk 'NF && !seen[$0]++')
N_DOMAINS=$(printf '%s\n' "$DOMAINS" | grep -c .)
[ "$N_DOMAINS" -gt 0 ] || die "域名列表为空"

TMP=$(mktemp -d 2>/dev/null) || die "创建临时目录失败"
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "${EPOCHREALTIME:-}" ]; then
  CLOCK="bash 内置 EPOCHREALTIME"
elif date +%s%3N 2>/dev/null | grep -qE '^[0-9]+$'; then
  CLOCK="GNU date %3N"
else
  CLOCK="date 整秒 (精度受限)"
fi

TMO_MODE="none"
TMO_DESC="内置兜底 (后台+kill)"
if command -v timeout >/dev/null 2>&1; then
  if timeout 1 true >/dev/null 2>&1; then
    TMO_MODE="gnu"; TMO_DESC="GNU timeout"
  elif timeout -t 1 true >/dev/null 2>&1; then
    TMO_MODE="busybox"; TMO_DESC="BusyBox timeout"
  fi
fi

run_with_timeout() {
  local secs="$1"; shift
  case "$TMO_MODE" in
    gnu) timeout "$secs" "$@" ;;
    busybox) timeout -t "$secs" "$@" ;;
    none)
      "$@" &
      local pid=$!
      ( sleep "$secs" 2>/dev/null; kill "$pid" 2>/dev/null ) &
      local killer=$!
      wait "$pid" 2>/dev/null
      local rc=$?
      kill "$killer" 2>/dev/null
      wait "$killer" 2>/dev/null
      return "$rc"
      ;;
  esac
}

now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    printf '%s' "${EPOCHREALTIME//./}" | cut -c1-13
  else
    local t
    t=$(date +%s%3N 2>/dev/null)
    case "$t" in
      ''|*[!0-9]*) printf '%s000' "$(date +%s)" ;;
      *) printf '%s' "$t" ;;
    esac
  fi
}

TLS13_CAP=no
if openssl s_client -help 2>&1 | grep -q -- '-tls1_3'; then
  TLS13_CAP=yes
fi

test_one() {
  local d="$1" out="$2"
  local t1 t2 ms status tls13 i okcnt failcnt sum avg elapsed slowfail
  tls13="n/a"
  okcnt=0
  failcnt=0
  sum=0
  slowfail=0
  for ((i = 0; i < ROUNDS; i++)); do
    t1=$(now_ms)
    if run_with_timeout "$TIMEOUT" openssl s_client -connect "$d:443" -servername "$d" </dev/null >/dev/null 2>&1; then
      t2=$(now_ms)
      ms=$((t2 - t1))
      [ "$ms" -lt 1 ] && ms=1
      sum=$((sum + ms))
      okcnt=$((okcnt + 1))
    else
      t2=$(now_ms)
      elapsed=$((t2 - t1))
      if [ "$elapsed" -ge $((TIMEOUT * 1000 - 150)) ]; then slowfail=1; fi
      failcnt=$((failcnt + 1))
    fi
  done
  if [ "$okcnt" -eq 0 ]; then
    ms=999999999
    if [ "$slowfail" -eq 1 ]; then status="TIMEOUT"; else status="FAIL"; fi
  else
    avg=$(((sum + okcnt / 2) / okcnt))
    [ "$avg" -lt 1 ] && avg=1
    ms="$avg"
    if [ "$failcnt" -eq 0 ]; then status="OK"; else status="PART"; fi
  fi
  if [ "$TLS13" -eq 1 ] && [ "$okcnt" -gt 0 ]; then
    if [ "$TLS13_CAP" = "yes" ]; then
      if run_with_timeout "$TIMEOUT" openssl s_client -tls1_3 -connect "$d:443" -servername "$d" </dev/null >/dev/null 2>&1; then
        tls13="yes"
      else
        tls13="no"
      fi
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$ms" "$status" "$tls13" "$d" "$okcnt/$ROUNDS" > "$out"
  printf '.' >&2
}

printf 'Reality 协议域名优选脚本 v%s\n' "$VERSION"
printf 'openssl: %s | 计时: %s | 超时工具: %s\n' \
  "$(openssl version 2>/dev/null || echo unknown)" "$CLOCK" "$TMO_DESC"
if [ "$TLS13" -eq 1 ] && [ "$TLS13_CAP" = "no" ]; then
  printf '警告: 当前 openssl 不支持 TLS 1.3, TLS1.3 列将显示 n/a\n' >&2
fi
if [ "$ROUNDS" -eq 1 ]; then
  ROUNDS_DESC="每域名 1 次"
else
  ROUNDS_DESC="每域名 $ROUNDS 次取平均"
fi
printf '超时: %ss | 并发: %s | %s | 域名数: %s\n\n' "$TIMEOUT" "$CONC" "$ROUNDS_DESC" "$N_DOMAINS"

idx=0
for d in $DOMAINS; do
  idx=$((idx + 1))
  test_one "$d" "$TMP/r$idx" &
  while [ "$(jobs -rp | wc -l)" -ge "$CONC" ]; do
    sleep 0.05 2>/dev/null || sleep 1
  done
done
wait
printf '\n' >&2

sort -t$'\t' -k1,1n -k4,4 "$TMP"/r* > "$TMP/all" 2>/dev/null

if [ "$TLS13" -eq 1 ]; then
  printf '%-4s  %-44s  %11s  %-6s\n' '#' 'DOMAIN' 'LATENCY' 'TLS1.3'
else
  printf '%-4s  %-44s  %11s\n' '#' 'DOMAIN' 'LATENCY'
fi

rank=0
ok=0
part=0
fail=0
best=""
best13=""
while IFS=$'\t' read -r ms status tls13 d okcnt; do
  if [ "$status" = "OK" ]; then
    ok=$((ok + 1))
    rank=$((rank + 1))
    [ -z "$best" ] && best="$d ($ms ms)"
    [ "$tls13" = "yes" ] && [ -z "$best13" ] && best13="$d ($ms ms)"
    if [ "$TOPN" -eq 0 ] || [ "$rank" -le "$TOPN" ]; then
      if [ "$TLS13" -eq 1 ]; then
        printf '%-4d  %-44s  %8d ms  %-6s\n' "$rank" "$d" "$ms" "$tls13"
      else
        printf '%-4d  %-44s  %8d ms\n' "$rank" "$d" "$ms"
      fi
    fi
  elif [ "$status" = "PART" ]; then
    part=$((part + 1))
    cell="$(printf '%d ms %s' "$ms" "$okcnt")"
    if [ "$TLS13" -eq 1 ]; then
      printf '%-4s  %-44s  %11s  %-6s\n' '-' "$d" "$cell" "$tls13"
    else
      printf '%-4s  %-44s  %11s\n' '-' "$d" "$cell"
    fi
  else
    fail=$((fail + 1))
    if [ "$TLS13" -eq 1 ]; then
      printf '%-4s  %-44s  %11s  %-6s\n' '-' "$d" "$status" "$tls13"
    else
      printf '%-4s  %-44s  %11s\n' '-' "$d" "$status"
    fi
  fi
done < "$TMP/all"

printf '\n'
summary="完成: 共 $N_DOMAINS 个域名, 稳定 $ok, 部分成功 $part, 失败/超时 $fail"
if [ "$TOPN" -gt 0 ] && [ "$rank" -gt "$TOPN" ]; then
  summary="$summary (仅显示最快前 $TOPN 个)"
fi
printf '%s\n' "$summary"
[ -n "$best" ] && printf '最快: %s\n' "$best"
[ -n "$best13" ] && printf 'Reality 推荐 (最快且支持 TLS1.3): %s\n' "$best13"

exit 0
