#!/usr/bin/env bash
#
# bdupload.sh —— 通用百度网盘上传脚本
#
# 对 BaiduPCS-Go 的一层封装，补上它没有的东西：排除规则、预演、
# tmux 后台、登录态预检、结构化日志。
#
# 依赖：同目录下的 bin/BaiduPCS-Go（跑 ./install.sh 装），或 PATH 上的 BaiduPCS-Go
#
# 快速上手：
#   ./bdupload.sh -s ./mydata -d /backup/mydata -x .cache
#   ./bdupload.sh -s ./mydata -d /backup -x '*.tmp' -x '*/logs/*' -n   # -n 先看会传啥
#   ./bdupload.sh -s ./mydata -d /backup -T mytask                     # 丢进 tmux 后台
#
set -uo pipefail

# ---------------------------------------------------------------- 默认值
SRCS=()                 # -s 可给多次
DST=""                  # -d 网盘目标目录
EXCLUDES=()             # -x 可给多次
THREADS=4               # -p 单文件上传线程数
LOAD=3                  # -l 同时上传的文件数
RETRY=5                 # --retry 失败重试次数
POLICY=skip             # --policy skip|overwrite|rsync
LOG=""                  # --log 日志路径，默认 ./<dst名>_upload.log
DRYRUN=0                # -n 只打印计划，不实际传
TMUX_SESSION=""         # -T 在 tmux 会话里后台跑

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
用法: bdupload.sh -s <本地路径> -d <网盘目录> [选项]

必选:
  -s, --src PATH        要上传的本地文件或目录。可重复指定，一次传多个。
  -d, --dst PATH        网盘上的目标目录，如 /backup/mydata。不存在会自动创建。

常用选项:
  -x, --exclude PAT     排除规则，可重复指定。
                        不含 / 时匹配文件名（如 .cache、*.tmp）
                        含 /  时匹配完整路径（如 '*/logs/*'）
                        目录结构会被保留，深层排除也能正确处理。
  -n, --dry-run         只打印将要上传什么、体积多大，不实际执行。
                        不需要二进制、也不需要登录，任何机器上都能先看一眼。
                        建议每次换新目录时先跑一遍。
  -T, --tmux NAME       在名为 NAME 的 tmux 会话里后台运行，断连不影响。
                        之后用 tmux attach -t NAME 查看进度。

调优选项:
  -p, --threads N       单个文件的上传线程数（默认 4）
  -l, --load N          同时上传的文件数（默认 3）
      --retry N         单文件失败重试次数（默认 5）
      --policy P        同名文件策略: skip(默认) / overwrite / rsync
                        skip = 跳过网盘已有的同名文件，也就是断点续传
      --log PATH        日志路径（默认 ./<网盘目录名>_upload.log）
  -h, --help            显示本帮助

路径映射:
  源是目录时，上传的是它的【内容】，不会再套一层同名目录：
      -s ./mydata -d /backup/mydata   =>   /backup/mydata/<mydata 里的东西>
  源是文件时，直接落在目标目录下：
      -s ./a.txt  -d /backup          =>   /backup/a.txt

行为说明:
  * 可重复执行。默认 --policy skip，中断后原样重跑即可，已传完的会跳过。
  * 上传前会检查登录态。没登录会提示怎么登录（需要 BDUSS + STOKEN）。
  * 秒传：百度若已存在相同哈希的文件会瞬间完成，不消耗流量，属正常现象。
  * 普通文件排在目录前面上传，几秒内就能确认链路通不通。

例子:
  # 传一个数据集，排除 HuggingFace 下载缓存
  ./bdupload.sh -s ./PianoVAM -d /datasets/PianoVAM -x .cache

  # 一次传多个源，排除临时文件，后台跑
  ./bdupload.sh -s ./modelA -s ./modelB -d /backup/models \
                -x '*.tmp' -x '*.ckpt.part' -T models

  # 先预演
  ./bdupload.sh -s ./bigdir -d /backup/bigdir -x .git -n
USAGE
}

# ---------------------------------------------------------------- 解析参数
while [ $# -gt 0 ]; do
  case "$1" in
    -s|--src)      SRCS+=("$2"); shift 2 ;;
    -d|--dst)      DST="$2"; shift 2 ;;
    -x|--exclude)  EXCLUDES+=("$2"); shift 2 ;;
    -p|--threads)  THREADS="$2"; shift 2 ;;
    -l|--load)     LOAD="$2"; shift 2 ;;
    --retry)       RETRY="$2"; shift 2 ;;
    --policy)      POLICY="$2"; shift 2 ;;
    --log)         LOG="$2"; shift 2 ;;
    -n|--dry-run)  DRYRUN=1; shift ;;
    -T|--tmux)     TMUX_SESSION="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; echo "用 -h 看帮助" >&2; exit 2 ;;
  esac
done

[ ${#SRCS[@]} -gt 0 ] || { echo "错误: 必须用 -s 指定源路径" >&2; usage; exit 2; }
[ -n "$DST" ]         || { echo "错误: 必须用 -d 指定网盘目标目录" >&2; usage; exit 2; }
case "$DST" in /*) ;; *) echo "错误: 网盘目录必须以 / 开头，当前是 '$DST'" >&2; exit 2 ;; esac

[ -n "$LOG" ] || LOG="$BASE/$(basename "$DST")_upload.log"

# ---------------------------------------------------------------- 找二进制
# 预演模式不碰网络，也就不需要二进制，这样在任何机器上都能先看一眼计划
PCS="$BASE/bin/BaiduPCS-Go"
if [ ! -x "$PCS" ]; then
  PCS="$(command -v BaiduPCS-Go 2>/dev/null)" || PCS=""
  if [ -z "$PCS" ] && [ "$DRYRUN" = 0 ]; then
    echo "错误: 找不到 BaiduPCS-Go（既不在 $BASE/bin/ 也不在 PATH 上）" >&2
    echo "      跑 ./install.sh 安装" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- 源路径检查
for s in "${SRCS[@]}"; do
  [ -e "$s" ] || { echo "错误: 源路径不存在: $s" >&2; exit 1; }
done

# ---------------------------------------------------------------- 转投 tmux
if [ -n "$TMUX_SESSION" ] && [ -z "${_BDUPLOAD_IN_TMUX:-}" ]; then
  command -v tmux >/dev/null || { echo "错误: 没装 tmux" >&2; exit 1; }
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "错误: tmux 会话 '$TMUX_SESSION' 已存在。" >&2
    echo "      查看: tmux attach -t $TMUX_SESSION" >&2
    echo "      清掉: tmux kill-session -t $TMUX_SESSION" >&2
    exit 1
  fi
  # 重建命令行（去掉 -T，避免无限递归）
  args=()
  for s in "${SRCS[@]}";     do args+=(-s "$s"); done
  for x in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do args+=(-x "$x"); done
  args+=(-d "$DST" -p "$THREADS" -l "$LOAD" --retry "$RETRY" --policy "$POLICY" --log "$LOG")
  [ "$DRYRUN" = 1 ] && args+=(-n)
  tmux new-session -d -s "$TMUX_SESSION" \
    "_BDUPLOAD_IN_TMUX=1 bash '${BASH_SOURCE[0]}' $(printf '%q ' "${args[@]}")"
  echo "已在 tmux 会话 '$TMUX_SESSION' 中启动。"
  echo "  看进度:   tmux attach -t $TMUX_SESSION   （退出看板: Ctrl-B 然后按 D）"
  echo "  或看日志: tail -f $LOG"
  exit 0
fi

# ---------------------------------------------------------------- 登录检查
if [ "$DRYRUN" = 1 ]; then
  who_out="(预演模式，跳过登录检查)"
else
  who_out="$("$PCS" who 2>&1)"
fi
case "$who_out" in
  *"用户名: ,"*|*"uid: 0,"*)
    echo "错误: 尚未登录百度账号。" >&2
    echo "$who_out" >&2
    echo >&2
    echo "登录方法（在 pan.baidu.com 页面按 F12 → Application → Cookies 取值）:" >&2
    echo "  $PCS login -bduss=\"你的BDUSS\" -stoken=\"你的STOKEN\"" >&2
    echo >&2
    echo "注意 STOKEN 不能省略 —— 只有 BDUSS 的话能查账号信息，但上传会失败，" >&2
    echo "报错是「获取用户uk错误, 请确保登录信息包含了STOKEN」。" >&2
    exit 1 ;;
esac

# ---------------------------------------------------------------- 排除规则
# 匹配 basename（规则不含 /）或完整路径（规则含 /）
is_excluded() {
  local path="$1" base pat
  base="$(basename "$path")"
  for pat in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
    case "$pat" in
      */*) [[ "$path" == $pat ]] && return 0 ;;
      *)   [[ "$base" == $pat ]] && return 0 ;;
    esac
  done
  return 1
}

# 子树里是否存在被排除项 —— 决定能否走"整目录上传"的快路径
subtree_has_exclusion() {
  local dir="$1" f
  [ ${#EXCLUDES[@]} -eq 0 ] && return 1
  while IFS= read -r f; do
    is_excluded "$f" && return 0
  done < <(find "$dir" -mindepth 1 2>/dev/null)
  return 1
}

# ---------------------------------------------------------------- 上传执行
PLAN_BYTES=0
PLAN_ITEMS=0

do_upload() {   # do_upload <网盘目标目录> <本地路径...>
  local dst="$1"; shift
  [ $# -eq 0 ] && return 0
  local it
  for it in "$@"; do
    PLAN_ITEMS=$((PLAN_ITEMS + 1))
    if [ "$DRYRUN" = 1 ]; then
      local sz; sz="$(du -sk "$it" 2>/dev/null | cut -f1)"; sz="${sz:-0}"
      PLAN_BYTES=$((PLAN_BYTES + sz))
      printf '  %-10s %s  ->  %s\n' "$(du -sh "$it" 2>/dev/null | cut -f1)" "$it" "$dst"
    fi
  done
  [ "$DRYRUN" = 1 ] && return 0

  "$PCS" upload \
    -p "$THREADS" -l "$LOAD" --retry "$RETRY" --policy "$POLICY" \
    "$@" "$dst" 2>&1 | tee -a "$LOG"
  return "${PIPESTATUS[0]}"
}

# walk <本地目录> <网盘父目录>
#   该目录最终落在 <网盘父目录>/<目录名>
#   子树干净 -> 整个目录一把传（快）；否则逐层下钻，保持目录结构
walk() {
  local dir="$1" remote_parent="$2"

  if ! subtree_has_exclusion "$dir"; then
    do_upload "$remote_parent" "$dir"
    return
  fi

  local remote_self="$remote_parent/$(basename "$dir")"
  local files=() subdirs=() entry

  while IFS= read -r entry; do
    is_excluded "$entry" && continue
    if [ -d "$entry" ]; then subdirs+=("$entry"); else files+=("$entry"); fi
  done < <(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | sort)

  [ ${#files[@]} -gt 0 ] && do_upload "$remote_self" "${files[@]}"
  for entry in ${subdirs[@]+"${subdirs[@]}"}; do
    walk "$entry" "$remote_self"
  done
}

# ---------------------------------------------------------------- 主流程
{
  echo "=== 开始 $(date '+%F %T')"
  echo "    源:       ${SRCS[*]}"
  echo "    网盘目录: $DST"
  [ ${#EXCLUDES[@]} -gt 0 ] && echo "    排除:     ${EXCLUDES[*]}"
  echo "    策略:     policy=$POLICY threads=$THREADS load=$LOAD retry=$RETRY"
} 2>&1 | tee -a "$LOG"

if [ "$DRYRUN" = 1 ]; then
  echo
  echo "===== 预演模式，不会实际上传 ====="
else
  "$PCS" quota 2>&1 | tee -a "$LOG"
  "$PCS" mkdir "$DST" >/dev/null 2>&1 || true
fi

rc=0
for s in "${SRCS[@]}"; do
  s="${s%/}"                                            # 去掉结尾的 /
  s="$(cd "$(dirname "$s")" && pwd)/$(basename "$s")"   # 转绝对路径

  if [ ! -d "$s" ]; then
    is_excluded "$s" || do_upload "$DST" "$s" || rc=$?
    continue
  fi

  # 源是目录：把它的【内容】铺到 $DST 下（而不是再套一层同名目录）
  # 干净的子项攒成一批走单次调用（BaiduPCS-Go 内部排队，进度显示也统一）；
  # 只有含排除项的子目录才逐层下钻。
  batch_files=(); batch_dirs=(); deferred=(); entry=""
  while IFS= read -r entry; do
    is_excluded "$entry" && continue
    if [ -d "$entry" ]; then
      if subtree_has_exclusion "$entry"; then deferred+=("$entry")
      else batch_dirs+=("$entry"); fi
    else
      batch_files+=("$entry")
    fi
  done < <(find "$s" -mindepth 1 -maxdepth 1 2>/dev/null | sort)

  # 普通文件排在目录前面：它们通常很小，几秒内就能确认链路是通的，
  # 不用等一个几十 G 的目录传到一半才发现登录态有问题。
  batch=(${batch_files[@]+"${batch_files[@]}"} ${batch_dirs[@]+"${batch_dirs[@]}"})
  [ ${#batch[@]} -gt 0 ] && { do_upload "$DST" "${batch[@]}" || rc=$?; }
  for entry in ${deferred[@]+"${deferred[@]}"}; do
    walk "$entry" "$DST" || rc=$?
  done
done

if [ "$DRYRUN" = 1 ]; then
  echo
  printf '共 %d 项，约 %s\n' "$PLAN_ITEMS" \
    "$(awk -v k="$PLAN_BYTES" 'BEGIN{s="KMGT";v=k;i=1;while(v>=1024&&i<4){v/=1024;i++}printf "%.1f%sB",v,substr(s,i,1)}')"
  echo "去掉 -n 即开始实际上传。"
  exit 0
fi

{
  echo "=== 结束 $(date '+%F %T') 退出码=$rc"
  echo "--- 网盘实际内容:"
  "$PCS" ls "$DST"
} 2>&1 | tee -a "$LOG"

exit "$rc"
