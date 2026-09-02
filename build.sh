#!/bin/bash
# build.sh - Build ATF + U-Boot for MediaTek MT798x platforms
#
# Usage:
#   BOARD=<board> [OPTIONS] ./build.sh
#   ./build.sh --clean
#   ./build.sh --help
#
# Required:
#   BOARD               Target board name (e.g. cmcc_a10, sn_r1)
#
# Optional:
#   SOC                 SoC: mt7981 | mt7986 | mt7987 | mt7988 (auto-detected if omitted)
#   VERSION             Firmware version: 2025 | SP1 | SP2        (default: 2025)
#   VARIANT             Build variant: default | ubootmod | ubi | nonmbm | openwrt
#                       (default: default)
#   FSTHEME             Failsafe UI theme: bootstrap | gl | mtk   (default: bootstrap)
#   FIXED_MTDPARTS      Enable fixed MTD partitions: 0 | 1        (default: 1)
#   MULTI_LAYOUT        Enable multi MTD layout: 0 | 1            (default: 0)
#   SIMG                Enable failsafe SIMG support: 0 | 1       (default: 0)
#   UBIMNG              Enable failsafe UBI management: 0 | 1     (default: 0)
#   TELNETD             Enable telnetd: 0 | 1                     (default: 0)
#   NAND_RAW            Enable NAND raw OOB backup: 0 | 1         (default: 0)
#   COPY_BL2            Copy bl2.img to output/: 0 | 1            (default: 1)
#   FIP_COMPRESS        Enable FIP image compression (XZ): 0 | 1  (default: 0)
#                       Compresses BL31, BL33 inside FIP to reduce file size
#
# Options:
#   --clean, -c         Distclean all source directories and exit
#   --help, -h          Show this help message and exit

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
step()    { echo -e "\n${BLUE}=== $* ===${NC}"; }
die()     { error "$*"; exit 1; }

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------
AUTHOR="Yuzhii"

TOOLCHAIN_ARM="arm-linux-gnueabi-"
TOOLCHAIN_AARCH64="aarch64-linux-gnu-"

# ATF / U-Boot source directory names
ATF24="atf-20240117-bacca82a8"
ATF25="atf-20250711"
ATF26="atf-20260123"
UBOOT25="uboot-mtk-20250711"

# User-configurable variables (with defaults)
VERSION="${VERSION:-2025}"
VARIANT="${VARIANT:-default}"
FSTHEME="${FSTHEME:-bootstrap}"
fixedparts="${FIXED_MTDPARTS:-1}"
multilayout="${MULTI_LAYOUT:-0}"
simg="${SIMG:-0}"
UBIMNG="${UBIMNG:-0}"
TELNETD="${TELNETD:-0}"
NAND_RAW="${NAND_RAW:-0}"
COPY_BL2="${COPY_BL2:-1}"
FIP_COMPRESS="${FIP_COMPRESS:-0}"
clean_mode=0

# Normalize case
VARIANT="${VARIANT,,}"
FSTHEME="${FSTHEME,,}"

# Config subdirectory names (under each source tree)
CONFIGS_DIR_DEFAULT="configs"
CONFIGS_DIR_FIT="configs-fit"
CONFIGS_DIR_UBI="configs-ubi"
CONFIGS_DIR_OPENWRT="configs-openwrt"
CONFIGS_DIR_NONMBM="configs-nonmbm"

# Helper: prompt user to disable multilayout
# Returns 0 (and sets multilayout=0) on consent, 1 on cancel
prompt_disable_multilayout() {
	warn "$1"
	local answer=""
	if [ "${SILENT}" != "Y" ]; then
		read -r answer
	fi
	if [ "${answer}" = "y" ] || [ "${answer}" = "Y" ] || [ "${SILENT}" = "Y" ]; then
		multilayout=0
		return 0
	else
		info "Canceled."
		return 1
	fi
}

#------------------------------------------------------------------------------
# --help / -h
#------------------------------------------------------------------------------
usage() {
	sed -n '2,/^[^#]/p' "$0" | grep -E '^#( |$)' | sed 's/^# \?//'
	exit 0
}

case "${1:-}" in
	--help|-h) usage ;;
	--clean|-c) clean_mode=1 ;;
esac

#------------------------------------------------------------------------------
# Resolve VERSION → UBOOT_DIR / ATF_DIR
#------------------------------------------------------------------------------
case "${VERSION}" in
	2025)
		UBOOT_DIR="${UBOOT25}"
		ATF_DIR="${ATF25}"
		;;
	SP1|sp1)
		VERSION="SP1"
		UBOOT_DIR="${UBOOT25}"
		ATF_DIR="${ATF24}"
		;;
	SP2|sp2)
		VERSION="SP2"
		UBOOT_DIR="${UBOOT25}"
		ATF_DIR="${ATF26}"
		;;
	*)
		error "Unsupported VERSION. Please specify VERSION=2025/SP1/SP2."
		exit 1
		;;
esac

#------------------------------------------------------------------------------
# Clean mode (early exit)
#------------------------------------------------------------------------------
if [ "${clean_mode}" = "1" ]; then
	step "Clean all source directories"
	for dir in "${UBOOT_DIR}" "${ATF24}" "${ATF25}" "${ATF26}"; do
		if [ -d "${dir}" ]; then
			info "Cleaning ${dir}"
			( cd "${dir}" && make distclean )
		else
			warn "${dir} does not exist."
		fi
	done
	info "Clean done."
	exit 0
fi

#------------------------------------------------------------------------------
# BOARD parameter check
#------------------------------------------------------------------------------
if [ -z "${BOARD}" ]; then
	error "BOARD is required. Run '$0 --help' for usage information."
	exit 1
fi

#------------------------------------------------------------------------------
# Auto-detect SOC if not specified
#------------------------------------------------------------------------------
detect_soc() {
	local matched=""
	local dir file base soc
	for dir in \
		"${UBOOT_DIR}/${CONFIGS_DIR_DEFAULT}" \
		"${UBOOT_DIR}/${CONFIGS_DIR_FIT}" \
		"${UBOOT_DIR}/${CONFIGS_DIR_UBI}" \
		"${UBOOT_DIR}/${CONFIGS_DIR_NONMBM}" \
		"${UBOOT_DIR}/${CONFIGS_DIR_OPENWRT}"; do
		[ -d "${dir}" ] || continue
		for file in "${dir}"/*_"${BOARD}"_defconfig "${dir}"/*_"${BOARD}"_multi_layout_defconfig; do
			[ -f "${file}" ] || continue
			base=$(basename "${file}")
			soc="${base%%_"${BOARD}"_defconfig}"
			if [ "${base}" = "${soc}" ]; then
				soc="${base%%_"${BOARD}"_multi_layout_defconfig}"
			fi
			matched="${matched} ${soc}"
		done
	done

	# Deduplicate
	local unique=""
	local s
	for s in ${matched}; do
		case " ${unique} " in
			*" ${s} "*) ;;
			*) unique="${unique} ${s}" ;;
		esac
	done

	set -- ${unique}
	local count=$#
	if [ "${count}" -eq 1 ]; then
		echo "$1"
		return 0
	elif [ "${count}" -gt 1 ]; then
		echo "${unique}"
		return 2
	fi
	return 1
}

if [ -z "${SOC}" ]; then
	SOC_DETECTED=$(detect_soc)
	status=$?
	if [ "${status}" -eq 0 ]; then
		SOC="${SOC_DETECTED}"
		info "Auto-detected SOC: ${SOC}"
	elif [ "${status}" -eq 2 ]; then
		error "Multiple SOC matches for BOARD=${BOARD}:${SOC_DETECTED}"
		error "Please set SOC manually."
		exit 1
	else
		error "Unable to auto-detect SOC for BOARD=${BOARD}"
		error "Please set SOC manually."
		exit 1
	fi
fi

SOC_UPPER="${SOC^^}"

# Config filenames (allow user override)
ATF_CFG="${ATF_CFG:-${SOC}_${BOARD}_defconfig}"
UBOOT_CFG="${UBOOT_CFG:-${SOC}_${BOARD}_defconfig}"
UBOOT_CFG_MULTILAYOUT="${UBOOT_CFG_MULTILAYOUT:-${SOC}_${BOARD}_multi_layout_defconfig}"

#------------------------------------------------------------------------------
# Ensure failsafe JS dependencies
#------------------------------------------------------------------------------
ensure_failsafe_js_deps() {
	local failsafe_dir="${UBOOT_DIR}/failsafe"
	local embed_dir="${failsafe_dir}/embedded"
	local package_json="${embed_dir}/package.json"
	local marker="${embed_dir}/.npm-install-done"

	if [ ! -f "${package_json}" ]; then
		info "Skipping failsafe JS dependency setup: ${package_json} not found."
		return 0
	fi

	if [ -f "${marker}" ] && [ -d "${embed_dir}/node_modules/terser" ] && [ -d "${embed_dir}/node_modules/clean-css" ] && [ -d "${embed_dir}/node_modules/html-minifier-terser" ]; then
		info "Failsafe JS build dependencies already installed."
		return 0
	fi

	command -v npm &>/dev/null || { error "npm is not installed on this system."; exit 1; }
	info "Installing failsafe JS build dependencies..."
	( cd "${embed_dir}" && npm install --no-audit --no-fund ) || exit 1
	touch "${marker}"
	info "Failsafe JS build dependencies installed."
}

#------------------------------------------------------------------------------
# Environment Check
#------------------------------------------------------------------------------
check_environment() {
	step "Environment Check [SOC: ${SOC_UPPER}] [BOARD: ${BOARD}]"

	# --- npm ---
	if ! command -v npm &>/dev/null; then
		error "npm is not installed on this system."
		exit 1
	fi
	info "npm: $(npm --version 2>&1)"

	info "Checking failsafe JS dependencies..."
	ensure_failsafe_js_deps

	# --- Python 3 ---
	if ! command -v python3 &>/dev/null; then
		error "Python3 is not installed on this system."
		exit 1
	fi
	info "Python3: $(python3 --version 2>&1)"

	# --- Cross Toolchain ---
	if [ -z "${TOOLCHAIN}" ]; then
		if [ "${SOC}" = "mt7629" ]; then
			TOOLCHAIN="${TOOLCHAIN_ARM}"
		else
			TOOLCHAIN="${TOOLCHAIN_AARCH64}"
		fi
		info "Using toolchain ${TOOLCHAIN} for SOC ${SOC}"
	fi
	if ! command -v "${TOOLCHAIN}gcc" &>/dev/null; then
		error "${TOOLCHAIN}gcc not found!"
		exit 1
	fi
	info "Toolchain: $(${TOOLCHAIN}gcc --version | head -1)"
	export CROSS_COMPILE="${TOOLCHAIN}"

	info "Environment Check passed"
}

#------------------------------------------------------------------------------
# Resolve Config Paths
#------------------------------------------------------------------------------
resolve_config_paths() {
	step "Resolve Config Paths"

	local atf_cfg_default="${ATF_DIR}/${CONFIGS_DIR_DEFAULT}/${ATF_CFG}"
	local atf_cfg_ubi="${ATF_DIR}/${CONFIGS_DIR_UBI}/${ATF_CFG}"
	local atf_cfg_openwrt="${ATF_DIR}/${CONFIGS_DIR_OPENWRT}/${ATF_CFG}"
	local atf_cfg_nonmbm="${ATF_DIR}/${CONFIGS_DIR_NONMBM}/${ATF_CFG}"

	local uboot_cfg_default="${UBOOT_DIR}/${CONFIGS_DIR_DEFAULT}/${UBOOT_CFG}"
	local uboot_cfg_multilayout="${UBOOT_DIR}/${CONFIGS_DIR_DEFAULT}/${UBOOT_CFG_MULTILAYOUT}"
	local uboot_cfg_fit="${UBOOT_DIR}/${CONFIGS_DIR_FIT}/${UBOOT_CFG}"
	local uboot_cfg_ubi="${UBOOT_DIR}/${CONFIGS_DIR_UBI}/${UBOOT_CFG}"
	local uboot_cfg_openwrt="${UBOOT_DIR}/${CONFIGS_DIR_OPENWRT}/${UBOOT_CFG}"
	local uboot_cfg_nonmbm="${UBOOT_DIR}/${CONFIGS_DIR_NONMBM}/${UBOOT_CFG}"
	local uboot_cfg_nonmbm_multilayout="${UBOOT_DIR}/${CONFIGS_DIR_NONMBM}/${UBOOT_CFG_MULTILAYOUT}"

	case "${VARIANT}" in
		default)
			ATF_CFG_PATH="${atf_cfg_default}"
			UBOOT_CFG_PATH="${uboot_cfg_default}"
			if [ "${multilayout}" = "1" ]; then
				UBOOT_CFG_PATH="${uboot_cfg_multilayout}"
			fi
			if [ "${multilayout}" = "1" ] && [ ! -f "${UBOOT_CFG_PATH}" ]; then
				if prompt_disable_multilayout "Multi layout config not found, will fallback to single-layout.(Y/n):"; then
					UBOOT_CFG_PATH="${uboot_cfg_default}"
				fi
			fi
			;;
		ubootmod)
			fixedparts=0
			ATF_CFG_PATH="${atf_cfg_default}"
			UBOOT_CFG_PATH="${uboot_cfg_fit}"
			if [ "${multilayout}" = "1" ]; then
				prompt_disable_multilayout "No multi layout with ubootmod variant, will disabled it.(Y/n):" || true
			fi
			;;
		ubi)
			fixedparts=0
			ATF_CFG_PATH="${atf_cfg_ubi}"
			UBOOT_CFG_PATH="${uboot_cfg_ubi}"
			if [ "${multilayout}" = "1" ]; then
				prompt_disable_multilayout "No multi layout with ubi variant, will disabled it.(Y/n):" || true
			fi
			;;
		openwrt)
			fixedparts=0
			ATF_CFG_PATH="${atf_cfg_default}"
			UBOOT_CFG_PATH="${uboot_cfg_openwrt}"
			if [ "${multilayout}" = "1" ]; then
				prompt_disable_multilayout "No multi layout with openwrt variant, will disabled it.(Y/n):" || true
			fi
			;;
		nonmbm)
			ATF_CFG_PATH="${atf_cfg_nonmbm}"
			UBOOT_CFG_PATH="${uboot_cfg_nonmbm}"
			if [ "${multilayout}" = "1" ]; then
				UBOOT_CFG_PATH="${uboot_cfg_nonmbm_multilayout}"
			fi
			if [ "${multilayout}" = "1" ] && [ ! -f "${UBOOT_CFG_PATH}" ]; then
				if prompt_disable_multilayout "Multi layout config not found, fallback to single-layout.(Y/n):"; then
					UBOOT_CFG_PATH="${uboot_cfg_nonmbm}"
				fi
			fi
			;;
		*)
			error "Unsupported VARIANT. Please specify VARIANT=default/ubootmod/ubi/nonmbm/openwrt."
			exit 1
			;;
	esac

	# EMMC builds: no fixed-mtdparts, no multilayout
	if grep -Eq "CONFIG_FLASH_DEVICE_EMMC=y|_BOOT_DEVICE_EMMC=y" "${ATF_CFG_PATH}"; then
		fixedparts=0
		multilayout=0
	fi

	if [ "${fixedparts}" = "0" ] && [ "${multilayout}" = "1" ]; then
		error "Multi layout is not compatible with fixed-mtdparts disabled build."
		error "Please disable multi layout or enable fixed-mtdparts."
		exit 1
	fi

	for file in "${ATF_CFG_PATH}" "${UBOOT_CFG_PATH}"; do
		if [ ! -f "${file}" ]; then
			error "${file} not found!"
			exit 1
		fi
	done
}

#------------------------------------------------------------------------------
# Print Configuration
#------------------------------------------------------------------------------
print_configuration() {
	step "Configuration"
	info "VERSION: ${VERSION}"
	info "VARIANT: ${VARIANT}"
	info "TARGET: ${SOC}_${BOARD}"
	info "ATF Dir: ${ATF_DIR}"
	info "U-Boot Dir: ${UBOOT_DIR}"
	info "ATF CFG: ${ATF_CFG_PATH}"
	info "U-Boot CFG: ${UBOOT_CFG_PATH}"
	info "Features: fixed-mtdparts: ${fixedparts}, multi-layout: ${multilayout}"
	info "Failsafe theme: ${FSTHEME}"
	info "Failsafe functions: SIMG support: ${simg}, UBI Management support: ${UBIMNG}"
	info "Telnetd support: ${TELNETD}, NAND RAW R/W support: ${NAND_RAW}"
	info "COPY BL2: ${COPY_BL2}"
	info "FIP Compression: ${FIP_COMPRESS}"
}

#------------------------------------------------------------------------------
# Build U-Boot
#------------------------------------------------------------------------------
build_uboot() {
	step "Build U-Boot [${SOC_UPPER}]"

	rm -f "${UBOOT_DIR}/u-boot.bin"
	cp -f "${UBOOT_CFG_PATH}" "${UBOOT_DIR}/.config"

	if [ "${fixedparts}" = "1" ]; then
		info "Build u-boot with fixed-mtdparts!"
		echo "CONFIG_MEDIATEK_UBI_FIXED_MTDPARTS=y" >> "${UBOOT_DIR}/.config"
		echo "CONFIG_MTK_FIXED_MTD_MTDPARTS=y" >> "${UBOOT_DIR}/.config"
	fi

	if [ -n "${VARIANT}" ]; then
		info "Build u-boot with variant: ${VARIANT}"
		echo "CONFIG_WEBUI_FAILSAFE_BUILD_VARIANT=\"${VARIANT}\"" >> "${UBOOT_DIR}/.config"
	fi

	case "${FSTHEME}" in
		bootstrap)
			info "Build u-boot with bootstrap fstheme!"
			;;
		gl)
			info "Build u-boot with gl fstheme!"
			echo "CONFIG_WEBUI_FAILSAFE_UI_GL=y" >> "${UBOOT_DIR}/.config"
			;;
		mtk)
			info "Build u-boot with mtk fstheme!"
			echo "CONFIG_WEBUI_FAILSAFE_UI_MTK=y" >> "${UBOOT_DIR}/.config"
			;;
		*)
			warn "Unknown FSTHEME: ${FSTHEME} (no theme config appended)"
			;;
	esac

	if [ "${simg}" = "1" ]; then
		info "Build u-boot with failsafe simg support!"
		echo "CONFIG_WEBUI_FAILSAFE_SIMG=y" >> "${UBOOT_DIR}/.config"
	fi
	if [ "${UBIMNG}" = "1" ]; then
		info "Build u-boot with failsafe UBI management support!"
		echo "CONFIG_WEBUI_FAILSAFE_UBI=y" >> "${UBOOT_DIR}/.config"
	fi
	if [ "${TELNETD}" = "1" ]; then
		info "Build u-boot with telnetd support!"
		echo "CONFIG_MTK_TELNETD=y" >> "${UBOOT_DIR}/.config"
	fi
	if [ "${NAND_RAW}" = "1" ]; then
		info "Build u-boot with NAND raw OOB backup support!"
		echo "CONFIG_WEBUI_FAILSAFE_NAND_RAW=y" >> "${UBOOT_DIR}/.config"
	fi

	make -C "${UBOOT_DIR}" olddefconfig
	make -C "${UBOOT_DIR}" clean
	make -C "${UBOOT_DIR}" -j "$(nproc)" all

	if [ -f "${UBOOT_DIR}/u-boot.bin" ]; then
		cp -f "${UBOOT_DIR}/u-boot.bin" "${ATF_DIR}/u-boot.bin"
		info "u-boot build done! ($(stat -c%s "${UBOOT_DIR}/u-boot.bin") bytes)"
	else
		error "u-boot build fail!"
		exit 1
	fi
}

#------------------------------------------------------------------------------
# Build ATF
#------------------------------------------------------------------------------
build_atf() {
	step "Build ATF [${SOC_UPPER}]"

	# Determine makefile name (some ATF trees use lowercase 'makefile')
	local atf_mkfile
	if [ -e "${ATF_DIR}/makefile" ]; then
		atf_mkfile="makefile"
	else
		atf_mkfile="Makefile"
	fi

	# Stage variant config if not in default configs/
	local atf_cfg_target="${ATF_CFG}"
	local atf_cfg_stage_file=""
	if [ "${ATF_CFG_PATH}" != "${ATF_DIR}/${CONFIGS_DIR_DEFAULT}/${ATF_CFG}" ]; then
		atf_cfg_target="__variant_${SOC}_${BOARD}_defconfig"
		atf_cfg_stage_file="${ATF_DIR}/${CONFIGS_DIR_DEFAULT}/${atf_cfg_target}"
		cp -f "${ATF_CFG_PATH}" "${atf_cfg_stage_file}"
		info "Staged ATF config: ${ATF_CFG_PATH} -> ${atf_cfg_stage_file}"
	fi

	make -C "${ATF_DIR}" -f "${atf_mkfile}" clean \
		CONFIG_CROSS_COMPILER="${TOOLCHAIN}" CROSS_COMPILER="${TOOLCHAIN}"
	rm -rf "${ATF_DIR}/build"
	make -C "${ATF_DIR}" -f "${atf_mkfile}" "${atf_cfg_target}" \
		CONFIG_CROSS_COMPILER="${TOOLCHAIN}" CROSS_COMPILER="${TOOLCHAIN}"

	if [ "${FIP_COMPRESS}" = "1" ]; then
		info "Enable FIP compression (XZ)..."
		sed -i 's/# _ENABLE_FIP_COMPRESS is not set/_ENABLE_FIP_COMPRESS=y/' "${ATF_DIR}/build/.config"
		printf 'FIP_COMPRESS=1\n' >> "${ATF_DIR}/build/.config"
	fi

	make -C "${ATF_DIR}" -f "${atf_mkfile}" all \
		CONFIG_CROSS_COMPILER="${TOOLCHAIN}" \
		CROSS_COMPILER="${TOOLCHAIN}" \
		CONFIG_BL33="../${UBOOT_DIR}/u-boot.bin" \
		BL33="../${UBOOT_DIR}/u-boot.bin" \
		-j "$(nproc)"

	if [ -n "${atf_cfg_stage_file}" ] && [ -f "${atf_cfg_stage_file}" ]; then
		rm -f "${atf_cfg_stage_file}"
	fi
}

#------------------------------------------------------------------------------
# Copy Output Files
#------------------------------------------------------------------------------
copy_outputs() {
	step "Copy Output Files"

	mkdir -p output

	local fip_bin="${ATF_DIR}/build/${SOC}/release/fip.bin"
	if [ ! -f "${fip_bin}" ]; then
		error "fip build fail!"
		exit 1
	fi

	local fip_name="fip-${SOC}_${BOARD}_${VERSION}-${AUTHOR}-dhcpd"
	case "${VARIANT}" in
		ubootmod) fip_name="${fip_name}-fit" ;;
		ubi)      fip_name="${fip_name}-ubi" ;;
		openwrt)  fip_name="${fip_name}-openwrt" ;;
		nonmbm)   fip_name="${fip_name}-nonmbm" ;;
	esac
	[ "${fixedparts}" = "1" ] && fip_name="${fip_name}-fixed-parts"
	[ "${multilayout}" = "1" ] && fip_name="${fip_name}-multi-layout"
	[ "${FIP_COMPRESS}" = "1" ] && fip_name="${fip_name}-fipc"

	local fip_md5
	fip_md5=$(md5sum "${fip_bin}" | awk '{print $1}')
	fip_name="${fip_name}_md5-${fip_md5}"

	info "fip-${SOC}_${BOARD}_${VERSION}_${VARIANT} build done"
	info "fip.bin md5sum: ${fip_md5}"
	info "fip.bin size: $(stat -c%s "${fip_bin}") bytes"
	cp -f "${fip_bin}" "output/${fip_name}.bin"
	info "Output: output/${fip_name}.bin"

	FIP_OUTPUT="output/${fip_name}.bin"

	# bl2.img only when no secure boot
	if grep -Eq "(^_|CONFIG_TARGET_ALL_NO_SEC_BOOT=y)" "${ATF_CFG_PATH}"; then
		local bl2_img="${ATF_DIR}/build/${SOC}/release/bl2.img"
		if [ ! -f "${bl2_img}" ]; then
			error "bl2 build fail!"
			exit 1
		fi

		local bl2_name="bl2-${SOC}_${BOARD}_${VERSION}"
		case "${VARIANT}" in
			ubootmod) bl2_name="${bl2_name}-fit" ;;
			ubi)      bl2_name="${bl2_name}-ubi" ;;
			openwrt)  bl2_name="${bl2_name}-openwrt" ;;
			nonmbm)   bl2_name="${bl2_name}-nonmbm" ;;
		esac

		local bl2_md5
		bl2_md5=$(md5sum "${bl2_img}" | awk '{print $1}')
		bl2_name="${bl2_name}_md5-${bl2_md5}"

		info "bl2-${SOC}_${BOARD}_${VERSION}_${VARIANT} build done"
		info "bl2.img md5sum: ${bl2_md5}"
		info "bl2.img size: $(stat -c%s "${bl2_img}") bytes"

		if [ "${COPY_BL2}" = "1" ]; then
			cp -f "${bl2_img}" "output/${bl2_name}.img"
			info "Output: output/${bl2_name}.img"
			BL2_OUTPUT="output/${bl2_name}.img"
		else
			info "Skipping bl2 copy because COPY_BL2 is disabled"
			info "You may find the bl2 image at: ${bl2_img}"
		fi
	fi
}

#------------------------------------------------------------------------------
# Print Summary
#------------------------------------------------------------------------------
print_summary() {
	echo ""
	echo "==========================================================================="
	echo -e "  ${GREEN}${SOC_UPPER} ${BOARD} (${VARIANT}) build completed!${NC}"
	echo "==========================================================================="
	echo ""
	echo "  Output directory: output/"
	echo ""

	local f size
	for f in "${FIP_OUTPUT}" "${BL2_OUTPUT}"; do
		[ -n "${f}" ] && [ -f "${f}" ] || continue
		size=$(stat -c%s "${f}")
		printf "    %-50s  %10s bytes\n" "${f}" "${size}"
	done
	echo ""
	echo "==========================================================================="
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
main() {
	echo ""
	echo "==========================================================================="
	echo "  MT798x ATF + U-Boot build script"
	echo "  SOC:      ${SOC_UPPER}"
	echo "  BOARD:    ${BOARD}"
	echo "  VERSION:  ${VERSION}"
	echo "  VARIANT:  ${VARIANT}"
	echo "==========================================================================="

	check_environment
	resolve_config_paths
	print_configuration
	build_uboot
	build_atf
	copy_outputs

	print_summary
}

main "$@"
