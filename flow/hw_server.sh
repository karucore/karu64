#!/usr/bin/env bash
#	hw_server.sh -- start/stop/status the Xilinx hardware server for JTAG.
#
#	The VCU118 flows (prog_vcu118_ddr / load_vcu118_ddr / release_vcu118_ddr,
#	and Vivado's hw_manager) connect to a hw_server on localhost:3121. This
#	wraps launching it inside the Vivado 2025.2.1 environment (like
#	with_vivado.sh), so the parent shell's sim toolchain stays unshadowed.
#
#	Idempotent: if a server is already listening on 3121 it does nothing.
#
#	Usage:
#	    flow/hw_server.sh            # ensure a daemon is running (default)
#	    flow/hw_server.sh status     # report whether one is up
#	    flow/hw_server.sh stop       # kill the running daemon
set -euo pipefail

PORT="${HW_SERVER_PORT:-3121}"
VIVADO_SETTINGS="${VIVADO_SETTINGS:-$HOME/Xilinx/2025.2.1/Vivado/.settings64-Vivado.sh}"

#	True if something is listening on $PORT (bash /dev/tcp probe; no ss/lsof dep).
port_up() {
	(exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
	return 1
}

cmd="${1:-start}"
case "$cmd" in
start)
	if port_up; then
		echo "hw_server: already listening on localhost:$PORT"
		exit 0
	fi
	if [ ! -r "$VIVADO_SETTINGS" ]; then
		echo "hw_server.sh: ERROR: cannot read $VIVADO_SETTINGS" >&2
		exit 1
	fi
	# shellcheck disable=SC1090
	source "$VIVADO_SETTINGS"
	echo "hw_server: starting daemon on localhost:$PORT ..."
	hw_server -d -s "tcp::$PORT"
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		port_up && { echo "hw_server: up on localhost:$PORT"; exit 0; }
		sleep 0.5
	done
	echo "hw_server.sh: ERROR: server did not come up on $PORT" >&2
	exit 1
	;;
status)
	if port_up; then
		echo "hw_server: listening on localhost:$PORT"
		pgrep -a hw_server || true
	else
		echo "hw_server: not running on localhost:$PORT"
		exit 1
	fi
	;;
stop)
	if pgrep -x hw_server >/dev/null; then
		pkill -x hw_server && echo "hw_server: stopped"
	else
		echo "hw_server: not running"
	fi
	;;
*)
	echo "usage: flow/hw_server.sh [start|status|stop]" >&2
	exit 2
	;;
esac
