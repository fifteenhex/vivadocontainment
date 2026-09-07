# vivadocontainment: put Vivado in the environment of login shells.
# Non-login shells (ssh host 'cmd') should use `vc-exec cmd` instead.

VIVADO_ROOT=@VIVADO_MNT@
export VIVADO_ROOT

if [ -n "@LICENSE@" ]; then
	XILINXD_LICENSE_FILE="@LICENSE@"
	export XILINXD_LICENSE_FILE
fi

# Sourced unconditionally: /etc/profile resets PATH for every login shell,
# so skipping this when XILINX_VIVADO is already exported leaves a nested
# login shell with the variables but no vivado on PATH.
# Three layouts in the wild:
#   <root>/Vivado/<version>/settings64.sh   up to 2023.x
#   <root>/<version>/Vivado/settings64.sh   2024.2 and later
#   <root>/Vivado/settings64.sh             either of those, when VIVADO_DIR
#                                           already points at the version dir
_vc_settings=
for _vc_s in "${VIVADO_ROOT}"/Vivado/*/settings64.sh \
             "${VIVADO_ROOT}"/*/Vivado/settings64.sh \
             "${VIVADO_ROOT}"/Vivado/settings64.sh; do
	[ -r "${_vc_s}" ] && _vc_settings="${_vc_s}"
done
if [ -n "${_vc_settings}" ]; then
	. "${_vc_settings}"
fi
unset _vc_s _vc_settings
