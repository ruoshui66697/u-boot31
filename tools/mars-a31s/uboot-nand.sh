#!/usr/bin/env bash
# =============================================================================
# MARS-A31s  /  U-Boot NAND 补丁脚本（Stage 1~3）
#
# 目标仓库 : ruoshui66697/u-boot31
# 放置位置 : tools/mars-a31s/uboot-nand.sh
# 运行位置 : 仓库根目录（脚本会自己 cd 到根）
# 由       : .github/workflows/build.yml 的 "Apply MARS-A31s U-Boot patches" 调用
#
# 设计要点
#  1. 源码树永远不进提交历史：脚本只在 CI 的 checkout 工作区里改文件，
#     改完立刻被 make 消费。想全撤 -> 把 build.yml 里调用本脚本那行注释掉。
#  2. 幂等：每次 apply 先查锚点/marker，已存在就 skip；上游哪天自己加了
#     MACH_SUN6I，脚本检测到直接跳过，不会冲突。
#  3. 单变量可分段：apply --up-to 1 / 2 / 3，每段跑完自检，失败即停。
#  4. 参数化：NAND 几何参数由环境变量注入，不写死在脚本正文里。
#     *** 未注入时用的是占位值，产物只能验编译，绝不能烧 NAND ***
#
# 用法
#   ./tools/mars-a31s/uboot-nand.sh apply --up-to 3
#   ./tools/mars-a31s/uboot-nand.sh apply --up-to 1
#   ./tools/mars-a31s/uboot-nand.sh status
#   ./tools/mars-a31s/uboot-nand.sh verify 2
#   ./tools/mars-a31s/uboot-nand.sh revert 3
#   ./tools/mars-a31s/uboot-nand.sh revert all
#
# 环境变量（全部可选，用于把上板实测真值回填，不改脚本正文）
#   MARS_NAND_PAGE_SIZE   页大小（data only）  默认 0x4000   [C 级占位]
#   MARS_NAND_OOBSIZE     OOB 大小             默认 0x4C0    [C 级占位]
#   MARS_NAND_BLOCK_SIZE  擦除块大小           默认 0x800000 [C 级占位]
#   MARS_MTDIDS           例 nand0=sunxi-nand.0   空=不写（等 mtd list 实测）
#   MARS_MTDPARTS         例 mtdparts=...         空=不写（属第 2 步分区轮）
#   MARS_A3_PINMUX        1=注入 pinctrl 块    默认 0（依赖 SPL 硬编码 mux）
# =============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

KCONFIG="drivers/mtd/nand/raw/Kconfig"
DEFCONFIG="configs/Sinlinx_SinA31s_defconfig"
BOARDDTS="arch/arm/dts/sun6i-a31s-sina31s.dts"

M2_BEGIN='# >>> MARS-A31s STAGE2 BEGIN <<<'
M2_END='# >>> MARS-A31s STAGE2 END <<<'
M3_BEGIN='/* >>> MARS-A31s STAGE3 BEGIN <<< */'
M3_END='/* >>> MARS-A31s STAGE3 END <<< */'

PAGE="${MARS_NAND_PAGE_SIZE:-0x4000}"
OOB="${MARS_NAND_OOBSIZE:-0x4C0}"
BLOCK="${MARS_NAND_BLOCK_SIZE:-0x800000}"
MTDIDS="${MARS_MTDIDS:-}"
MTDPARTS="${MARS_MTDPARTS:-}"
A3_PINMUX="${MARS_A3_PINMUX:-0}"

# 三个几何值只要有一个没显式给，整轮产物就标记为 COMPILE-ONLY
PLACEHOLDER=0
if [ -z "${MARS_NAND_PAGE_SIZE:-}" ] || \
   [ -z "${MARS_NAND_OOBSIZE:-}" ] || \
   [ -z "${MARS_NAND_BLOCK_SIZE:-}" ]; then
    PLACEHOLDER=1
fi

log()  { printf '[mars] %s\n' "$*"; }
warn() { printf '[mars][WARN] %s\n' "$*" >&2; }
die()  { printf '[mars][FATAL] %s\n' "$*" >&2; exit 1; }

for f in "$KCONFIG" "$DEFCONFIG" "$BOARDDTS"; do
    [ -f "$f" ] || die "缺少文件：$f（请在 u-boot31 仓库根目录运行）"
done

# -----------------------------------------------------------------------------
# Stage 1 / A1 : drivers/mtd/nand/raw/Kconfig 打开 MACH_SUN6I 门
# -----------------------------------------------------------------------------
s1_apply() {
MARS_KCONFIG="$KCONFIG" python3 - <<'PY'
import os, sys
p = os.environ['MARS_KCONFIG']
s = open(p, encoding='utf-8').read()
old = "\t\t|| MACH_SUN50I_H616 || MACH_SUN50I_H6\n"
new = "\t\t|| MACH_SUN50I_H616 || MACH_SUN50I_H6 || MACH_SUN6I\n"
if new in s:
    print("  stage1: 已应用 -> skip")
    sys.exit(0)
n = s.count(old)
if n != 1:
    print("  stage1: 锚点命中 %d 次（应为 1），拒绝改动" % n, file=sys.stderr)
    sys.exit(1)
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
print("  stage1: Kconfig depends on 追加 || MACH_SUN6I")
PY
}

s1_revert() {
MARS_KCONFIG="$KCONFIG" python3 - <<'PY'
import os, sys
p = os.environ['MARS_KCONFIG']
s = open(p, encoding='utf-8').read()
new = "\t\t|| MACH_SUN50I_H616 || MACH_SUN50I_H6 || MACH_SUN6I\n"
old = "\t\t|| MACH_SUN50I_H616 || MACH_SUN50I_H6\n"
if new not in s:
    print("  stage1: 未应用 -> skip"); sys.exit(0)
open(p, 'w', encoding='utf-8').write(s.replace(new, old, 1))
print("  stage1: 已回退")
PY
}

s1_verify() {
MARS_KCONFIG="$KCONFIG" python3 - <<'PY'
import os, sys
s = open(os.environ['MARS_KCONFIG'], encoding='utf-8').read()
needle = "\t\t|| MACH_SUN50I_H616 || MACH_SUN50I_H6 || MACH_SUN6I\n"
print("  stage1 verify: " + ("OK" if needle in s else "FAIL"))
sys.exit(0 if needle in s else 1)
PY
}

s1_state() {
MARS_KCONFIG="$KCONFIG" python3 - <<'PY'
import os
s = open(os.environ['MARS_KCONFIG'], encoding='utf-8').read()
print("applied" if "|| MACH_SUN50I_H616 || MACH_SUN50I_H6 || MACH_SUN6I" in s else "clean")
PY
}

# -----------------------------------------------------------------------------
# Stage 2 / A2 : defconfig 追加 NAND 开关组（保留原有 20 行）
# -----------------------------------------------------------------------------
s2_apply() {
MARS_DEFCONFIG="$DEFCONFIG" MARS_BEGIN="$M2_BEGIN" MARS_END="$M2_END" \
MARS_PAGE="$PAGE" MARS_OOB="$OOB" MARS_BLOCK="$BLOCK" \
MARS_MTDIDS="$MTDIDS" MARS_MTDPARTS="$MTDPARTS" python3 - <<'PY'
import os, sys
p = os.environ['MARS_DEFCONFIG']
s = open(p, encoding='utf-8').read()
b, e = os.environ['MARS_BEGIN'], os.environ['MARS_END']
if b in s:
    print("  stage2: 已应用 -> skip"); sys.exit(0)
L = [
    "CONFIG_MTD=y",
    "CONFIG_MTD_RAW_NAND=y",
    "CONFIG_NAND_SUNXI=y",
    "CONFIG_DM_MTD=y",
    "CONFIG_SPL_MTD_SUPPORT=y",
    "CONFIG_CMD_NAND=y",
    "CONFIG_CMD_MTD=y",
    "CONFIG_SYS_NAND_U_BOOT_OFFS=0x800000",
    "CONFIG_SYS_NAND_PAGE_SIZE=" + os.environ['MARS_PAGE'],
    "CONFIG_SYS_NAND_OOBSIZE=" + os.environ['MARS_OOB'],
    "CONFIG_SYS_NAND_BLOCK_SIZE=" + os.environ['MARS_BLOCK'],
]
if os.environ.get('MARS_MTDIDS'):
    L.append('CONFIG_MTDIDS_DEFAULT="' + os.environ['MARS_MTDIDS'] + '"')
if os.environ.get('MARS_MTDPARTS'):
    L.append('CONFIG_MTDPARTS_DEFAULT="' + os.environ['MARS_MTDPARTS'] + '"')
block = "\n".join([b] + L + [e]) + "\n"
if not s.endswith("\n"):
    s += "\n"
open(p, 'w', encoding='utf-8').write(s + block)
print("  stage2: 追加 %d 行 NAND 开关（原 20 行保留）" % len(L))
PY
}

s2_revert() {
MARS_DEFCONFIG="$DEFCONFIG" MARS_BEGIN="$M2_BEGIN" MARS_END="$M2_END" python3 - <<'PY'
import os, re, sys
p = os.environ['MARS_DEFCONFIG']
s = open(p, encoding='utf-8').read()
b, e = os.environ['MARS_BEGIN'], os.environ['MARS_END']
pat = re.escape(b) + r".*?" + re.escape(e) + r"\n?"
s2, n = re.subn(pat, "", s, flags=re.S)
if n == 0:
    print("  stage2: 未应用 -> skip"); sys.exit(0)
open(p, 'w', encoding='utf-8').write(s2.rstrip() + "\n")
print("  stage2: 已回退")
PY
}

s2_verify() {
MARS_DEFCONFIG="$DEFCONFIG" MARS_BEGIN="$M2_BEGIN" MARS_END="$M2_END" python3 - <<'PY'
import os, sys
s = open(os.environ['MARS_DEFCONFIG'], encoding='utf-8').read()
b, e = os.environ['MARS_BEGIN'], os.environ['MARS_END']
keys = ["CONFIG_NAND_SUNXI=y", "CONFIG_MTD_RAW_NAND=y", "CONFIG_CMD_NAND=y",
        "CONFIG_SYS_NAND_U_BOOT_OFFS=0x800000", "CONFIG_SYS_NAND_PAGE_SIZE=",
        "CONFIG_SYS_NAND_OOBSIZE=", "CONFIG_SYS_NAND_BLOCK_SIZE="]
ok = (b in s and e in s and all(k in s for k in keys))
print("  stage2 verify: " + ("OK" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PY
}

s2_state() {
MARS_DEFCONFIG="$DEFCONFIG" MARS_BEGIN="$M2_BEGIN" python3 - <<'PY'
import os
s = open(os.environ['MARS_DEFCONFIG'], encoding='utf-8').read()
print("applied" if os.environ['MARS_BEGIN'] in s else "clean")
PY
}

# -----------------------------------------------------------------------------
# Stage 3 / A3 : 板级 DTS 注入 NFC 节点 + 禁用 mmc3
# -----------------------------------------------------------------------------
s3_apply() {
MARS_BOARDDTS="$BOARDDTS" MARS_BEGIN="$M3_BEGIN" MARS_END="$M3_END" \
MARS_PINMUX="$A3_PINMUX" python3 - <<'PY'
import os, sys
p = os.environ['MARS_BOARDDTS']
s = open(p, encoding='utf-8').read()
b, e = os.environ['MARS_BEGIN'], os.environ['MARS_END']
if b in s:
    print("  stage3: 已应用 -> skip"); sys.exit(0)

L = [
    b,
    "/ {",
    "\tsoc {",
    "\t\tnfc: nand@1c03000 {",
    "\t\t\tcompatible = \"allwinner,sun4i-a10-nand\";",
    "\t\t\treg = <0x01c03000 0x1000>;",
    "\t\t\tinterrupts = <GIC_SPI 13 IRQ_TYPE_LEVEL_HIGH>;",
    "\t\t\tclocks = <&ccu CLK_AHB1_NAND0>, <&ccu CLK_NAND0>;",
    "\t\t\tclock-names = \"ahb\", \"mod\";",
    "\t\t\tresets = <&ccu RST_AHB1_NAND0>;",
    "\t\t\t#address-cells = <1>;",
    "\t\t\t#size-cells = <0>;",
    "\t\t\tstatus = \"disabled\";",
    "\t\t};",
    "\t};",
    "};",
    "",
]

if os.environ['MARS_PINMUX'] == '1':
    # C 级脚位（2015 未合入 patch），默认不启用；启用前须核对 sun6i pinctrl
    # driver 是否认 "nand0" function。默认依赖 SPL 的 board_nand_init() 硬编码 mux。
    L += [
        "&pio {",
        "\tmars_nand_pins: mars-nand-pins {",
        "\t\tpins = \"PC0\", \"PC1\", \"PC2\", \"PC5\", \"PC8\", \"PC9\",",
        "\t\t       \"PC10\", \"PC11\", \"PC12\", \"PC13\", \"PC14\",",
        "\t\t       \"PC15\", \"PC16\";",
        "\t\tfunction = \"nand0\";",
        "\t};",
        "};",
        "",
    ]

L += ["&nfc {", "\tstatus = \"okay\";"]
if os.environ['MARS_PINMUX'] == '1':
    L += ["\tpinctrl-names = \"default\";", "\tpinctrl-0 = <&mars_nand_pins>;"]
L += [
    "\tnand@0 {",
    "\t\treg = <0>;",
    "\t\tnand-ecc-mode = \"hw\";",
    "\t};",
    "};",
    "",
    "/* eMMC on core board 占用 PC6-PC15+PC24，与 NAND 的 PC 组冲突 */",
    "&mmc3 {",
    "\tstatus = \"disabled\";",
    "};",
    e,
]
block = "\n".join(L) + "\n"
if not s.endswith("\n"):
    s += "\n"
open(p, 'w', encoding='utf-8').write(s + "\n" + block)
print("  stage3: 注入 nfc 节点 + &mmc3 disabled（pinmux=%s）" % os.environ['MARS_PINMUX'])
PY
}

s3_revert() {
MARS_BOARDDTS="$BOARDDTS" MARS_BEGIN="$M3_BEGIN" MARS_END="$M3_END" python3 - <<'PY'
import os, re, sys
p = os.environ['MARS_BOARDDTS']
s = open(p, encoding='utf-8').read()
b, e = os.environ['MARS_BEGIN'], os.environ['MARS_END']
pat = re.escape(b) + r".*?" + re.escape(e) + r"\n?"
s2, n = re.subn(pat, "", s, flags=re.S)
if n == 0:
    print("  stage3: 未应用 -> skip"); sys.exit(0)
open(p, 'w', encoding='utf-8').write(s2.rstrip() + "\n")
print("  stage3: 已回退")
PY
}

s3_verify() {
MARS_BOARDDTS="$BOARDDTS" MARS_BEGIN="$M3_BEGIN" MARS_END="$M3_END" python3 - <<'PY'
import os, sys
s = open(os.environ['MARS_BOARDDTS'], encoding='utf-8').read()
b, e = os.environ['MARS_BEGIN'], os.environ['MARS_END']
keys = ["nfc: nand@1c03000", 'compatible = "allwinner,sun4i-a10-nand"',
        "CLK_AHB1_NAND0", "CLK_NAND0", "&mmc3 {", 'status = "disabled"']
ok = (b in s and e in s and all(k in s for k in keys))
print("  stage3 verify: " + ("OK" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PY
}

s3_state() {
MARS_BOARDDTS="$BOARDDTS" MARS_BEGIN="$M3_BEGIN" python3 - <<'PY'
import os
s = open(os.environ['MARS_BOARDDTS'], encoding='utf-8').read()
print("applied" if os.environ['MARS_BEGIN'] in s else "clean")
PY
}

# -----------------------------------------------------------------------------
# 编排
# -----------------------------------------------------------------------------
write_status() {
    local s1 s2 s3
    s1="$(s1_state)"; s2="$(s2_state)"; s3="$(s3_state)"
    cat > "$ROOT/.mars-a31s-status" <<EOF
stage1=$s1
stage2=$s2
stage3=$s3
compile_only=$PLACEHOLDER
page=$PAGE
oob=$OOB
block=$BLOCK
mtdids=${MTDIDS:-<unset>}
mtdparts=${MTDPARTS:-<unset>}
a3_pinmux=$A3_PINMUX
EOF
}

cmd_apply() {
    local upto=3
    if [ "${1:-}" = "--up-to" ]; then upto="${2:-3}"; fi
    case "$upto" in 1|2|3) ;; *) die "--up-to 只能是 1 / 2 / 3" ;; esac
    log "ROOT=$ROOT  up-to=$upto"
    for n in 1 2 3; do
        [ "$n" -le "$upto" ] || break
        log "=== STAGE $n apply ==="
        "s${n}_apply"
        if ! "s${n}_verify"; then
            die "stage $n 自检未过 -> 先跑：$0 revert $n"
        fi
        log "=== STAGE $n checkpoint OK ==="
    done
    write_status
    log "参数: PAGE=$PAGE OOB=$OOB BLOCK=$BLOCK MTDIDS=${MTDIDS:-<unset>} MTDPARTS=${MTDPARTS:-<unset>} PINMUX=$A3_PINMUX"
    if [ "$PLACEHOLDER" -eq 1 ]; then
        warn "============================================================"
        warn "COMPILE-ONLY：三个 NAND 几何参数用的是 C 级占位值"
        warn "（$PAGE / $OOB / $BLOCK），不是本片实测 ONFI 真值。"
        warn "本轮产物只能验编译，*** 绝不能拿去烧 NAND ***。"
        warn "上板 nand info 拿到真值后，用环境变量回填即可，无需改本脚本："
        warn "  MARS_NAND_PAGE_SIZE=... MARS_NAND_OOBSIZE=... \\"
        warn "  MARS_NAND_BLOCK_SIZE=... ./tools/mars-a31s/uboot-nand.sh apply --up-to 3"
        warn "============================================================"
    else
        log "三个几何参数均由外部显式注入 -> compile_only=0（仍需 L1 板测确认）"
    fi
}

cmd_revert() {
    local target="${1:-all}"
    local seq
    case "$target" in
        all) seq="3 2 1" ;;
        1|2|3) seq="$target" ;;
        *) die "revert 只接受 1 / 2 / 3 / all" ;;
    esac
    for n in $seq; do
        log "=== STAGE $n revert ==="
        "s${n}_revert"
    done
    write_status
    log "回退完成。若 build.yml 仍调用本脚本，下一次 CI 会重新按 --up-to 应用。"
    log "想彻底停用：注释掉 build.yml 里 'Apply MARS-A31s U-Boot patches' 那一段。"
}

cmd_verify() {
    local n="${1:-3}"
    case "$n" in 1|2|3) ;; *) die "verify 只接受 1 / 2 / 3" ;; esac
    "s${n}_verify"
}

cmd_status() {
    log "stage1 = $(s1_state)"
    log "stage2 = $(s2_state)"
    log "stage3 = $(s3_state)"
    log "compile_only = $PLACEHOLDER  (PAGE=$PAGE OOB=$OOB BLOCK=$BLOCK)"
    log "A3 pinmux = $A3_PINMUX   MTDIDS=${MTDIDS:-<unset>}   MTDPARTS=${MTDPARTS:-<unset>}"
    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log "--- git diff --stat（tracked 改动，仅本脚本产生）---"
        git -C "$ROOT" diff --stat -- "$KCONFIG" "$DEFCONFIG" "$BOARDDTS" || true
    fi
}

usage() {
    cat <<EOF
用法: $0 <command> [args]

  apply --up-to N  应用 stage 1..N（N=1/2/3，默认 3），逐段自检
  revert N|all     回退单个 stage 或全部（默认 all）
  verify N         只校验 stage N，不改文件
  status           报各 stage 状态 + 参数 + git diff
EOF
}

case "${1:-}" in
    apply)  shift; cmd_apply "$@" ;;
    revert) shift; cmd_revert "${1:-all}" ;;
    verify) shift; cmd_verify "${1:-3}" ;;
    status) cmd_status ;;
    *) usage; exit 0 ;;
esac
