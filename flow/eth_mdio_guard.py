#!/usr/bin/env python3
# eth_mdio_guard.py <liteeth_core.v>
# Post-process a generated LiteEth standalone core for the karu64 DDR/SGMII builds.
# Two idempotent transforms (each a no-op if already applied / not present):
#
#  1) MDIO IOBUF guard -- wrap the LiteEth MDIO `IOBUF` in `KARU_ETH_NO_MDIO_IOBUF`
#     (-> `assign <data_r> = 1'b1;` when set). With the define the build drops the
#     internal IOBUF (unplaceable with no board MDIO pin, and a second MDIO path vs
#     karu_dp83867_mdio). Works for the MII core (.O=maccore_data_r, mii_mdio) and the
#     GMII core (.O=maccore_ethphy_data_r, gmii_mdio): the .O net is detected.
#
#  2) gtx ODDR removal (GMII core only) -- the LiteEthPHYGMII CRG forwards the GMII TX
#     clock to an EXTERNAL PHY via an ODDRE1 driving gmii_clocks_gtx. On an on-chip PCS
#     there is no gtx pin, so that ODDR floats and IO placement fails
#     (`[Place 30-1114] Floating OSERDES ODDRE1`). eth_tx is independently clocked by
#     clk125 (CRG: eth_tx_clk = clock_pads.rx), so the forward is dead weight: replace
#     the ODDRE1 with `assign gmii_clocks_gtx = 1'b0;`.
#
# Called by flow/fpga/eth/regen.sh after each core is generated (reproducible, not a hand-edit).
import re, sys

path = sys.argv[1]
s = orig = open(path).read()
changed = []

# 1) MDIO IOBUF guard
if "KARU_ETH_NO_MDIO_IOBUF" not in s:
    m = re.search(r"(IOBUF\s+IOBUF\s*\(.*?\.O\s*\(\s*(\w+)\s*\).*?\);)", s, re.S)
    if m:
        block, net = m.group(1), m.group(2)
        guarded = (
            "`ifdef KARU_ETH_NO_MDIO_IOBUF\n"
            "// No board MDIO pin in this build (the external PHY is managed by\n"
            "// karu_dp83867_mdio); keep the LiteEth MDIO read side idle instead of an\n"
            "// unplaceable internal IO primitive / a second MDIO path.\n"
            "assign %s = 1'b1;\n"
            "`else\n%s\n`endif" % (net, block)
        )
        s = s[:m.start(1)] + guarded + s[m.end(1):]
        changed.append("MDIO IOBUF guarded (.O=%s)" % net)

# 2) gtx ODDR removal (GMII core)
m2 = re.search(r"(ODDRE1\s+ODDRE1\s*\(.*?\.Q\s*\(\s*(gmii_clocks_gtx)\s*\).*?\);)", s, re.S)
if m2:
    net = m2.group(2)
    repl = (
        "// gtx TX-clock forward removed: eth_tx is clocked by clk125 via the CRG, and\n"
        "// the on-chip PCS/PMA needs no forwarded TX clock -- so the ODDRE1 would float\n"
        "// (Place 30-1114). Tie the unused output instead.\n"
        "assign %s = 1'b0;" % net
    )
    s = s[:m2.start(1)] + repl + s[m2.end(1):]
    changed.append("gtx ODDRE1 removed (.Q=%s)" % net)

if s != orig:
    open(path, "w").write(s)
print("eth_mdio_guard: %s -- %s" % (path, ", ".join(changed) if changed else "no changes"))
