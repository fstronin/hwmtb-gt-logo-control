#!/bin/bash
# find_logo.sh - interactive search for the EC register that drives the lid
# "logo light" on a HUAWEI laptop.
#
# Run it from a terminal and watch the logo on the lid while it walks the
# candidate registers of the EC RAM space (offsets that HUAWEI's own ACPI
# tables never touch).  Answer y/n for each step; on "y" the value is kept.
#
#   sudo bash find_logo.sh              # default candidate order
#   sudo bash find_logo.sh 0x78 0x79    # or an explicit list
#
# Requires write access to /proc/acpi/call (package acpi-call-dkms).
set -u

CALL='\_SB.PC00.LPCB.HWEC.ECCD'
PROC=/proc/acpi/call
RES=/tmp/hwlogo-found.conf

[ -w "$PROC" ] || { echo "no write access to $PROC (run as root / install acpi-call-dkms)"; exit 1; }

rd() { printf '%s 0x02 0x%02x 0x00 {0x00} 0x100' "$CALL" "$1" > "$PROC"
       tr -d '{}' < "$PROC" | tr -d '\n ' | cut -d, -f1-4; }
wr() { printf '%s 0x02 0x%02x 0x01 b%02x 0x100' "$CALL" "$1" "$2" > "$PROC"
       tr -d '{}' < "$PROC" | tr -d '\n ' | cut -d, -f1-3; }

# blink with both plausible encodings: 0x5a/0x55 ("open"/"close", as used by
# the microphone LED on EC 0x77) and 0x04/0x00 ("bright"/"off", as used by the
# keyboard backlight on EC 0x65)
bg() { wr "$1" 0x5a >/dev/null; sleep 1; wr "$1" 0x55 >/dev/null; sleep 1; }
lv() { wr "$1" 0x04 >/dev/null; sleep 2; wr "$1" 0x00 >/dev/null; sleep 1; }

# offsets in 0x60..0x9f that no method in the DSDT/SSDTs accesses
DEFAULT="0x66 0x78 0x79 0x76 0x6a 0x60 0x7d 0x6d 0x6e 0x6f 0x70 0x71 0x72 0x73 0x74 0x75 \
0x80 0x86 0x87 0x8d 0x8e 0x8f 0x91 0x93 0x94 0x95 0x96 0x97 0x98 0x99 0x9b 0x9f"
CANDS="${*:-$DEFAULT}"

cat <<'EOF'
=== searching for the lid logo light EC register ===
Watch the HUAWEI logo on the lid.  For every candidate the script blinks it
twice with 0x5a/0x55 and then with 0x04/0x00, and asks whether anything
happened.

  y - yes, the logo reacted (the script keeps it on and stops)
  n - no, next candidate
  q - quit
  v - write your own value into this register and check it
EOF
echo

n=0
for off in $CANDS; do
	o=$((off))
	n=$((n+1))
	printf '[%2d] EC %s (now %s): blinking ... ' "$n" "$off" "$(rd "$o")"
	bg "$o"; lv "$o"
	echo "done"
	read -r -p "     did the logo blink / light up? [y/n/q/v] " a
	case "$a" in
	y|Y)
		echo "     keeping 0x5a ..."; wr "$o" 0x5a >/dev/null; sleep 1
		read -r -p "     is the logo lit now? [y/n] " c
		if [ "$c" = y ] || [ "$c" = Y ]; then
			printf 'REG=%s\nOFF=0x55\nON=0x5a\n' "$off" > "$RES"
			echo "== FOUND: EC $off, ON=0x5a, OFF=0x55 =="
			exit 0
		fi
		echo "     trying level value 0x04 ..."; wr "$o" 0x04 >/dev/null; sleep 2
		read -r -p "     lit on 0x04? [y/n] " c2
		if [ "$c2" = y ] || [ "$c2" = Y ]; then
			printf 'REG=%s\nOFF=0x00\nON=0x04\n' "$off" > "$RES"
			echo "== FOUND: EC $off, ON=0x04, OFF=0x00 =="
			exit 0
		fi
		wr "$o" 0x55 >/dev/null
		;;
	q|Q)
		wr "$o" 0x55 >/dev/null
		echo "stopped"
		exit 1
		;;
	v|V)
		read -r -p "     value (hex, e.g. 01): " hv
		wr "$o" "$((16#$hv))" >/dev/null; sleep 2
		read -r -p "     did it light up? [y/n] " b
		if [ "$b" = y ] || [ "$b" = Y ]; then
			printf 'REG=%s\nON=0x%s\n' "$off" "$hv" > "$RES"
			echo "== FOUND: EC $off = 0x$hv =="
			exit 0
		fi
		wr "$o" 0x55 >/dev/null
		;;
	esac
	wr "$o" 0x55 >/dev/null
done

echo "all candidates tested, no reaction. Report the result."
