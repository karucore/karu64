// SPDX-License-Identifier: BSD-3-Clause
// Independent opt-in extension switches; KARU_DBG retains the base DM.
`ifndef KARUDBG_CFG_VH
`define KARUDBG_CFG_VH
`ifdef KARU_DBG_FULL
`ifndef KARU_DBG_AUTOEXEC
`define KARU_DBG_AUTOEXEC
`endif
`ifndef KARU_DBG_TRIGGERS
`define KARU_DBG_TRIGGERS
`endif
`ifndef KARU_DBG_SBA
`define KARU_DBG_SBA
`endif
`endif
`endif
