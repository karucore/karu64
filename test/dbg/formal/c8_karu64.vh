// SPDX-License-Identifier: BSD-2-Clause
// Property block spliced into a build copy of the module by
// test/dbg/run_auth_formal.py (plan 5.2); it reads the module internals.
    // ---- formal lemma C8 (plan 5.2): provenance at cut K2. From an
    // arbitrary state, with every submodule except the CSR file free, an
    // authentication-CSR commit is reported only for an issuing CSR
    // instruction outside reset that neither traps nor enters Debug Mode in
    // that cycle; boot_exit_now's inputs are the trap/issue/entry signals.
    always @* if (auth_fire_o) begin
        assert(!rst && issuing && ex_unit == `UNIT_CSR);
        assert(!trap_req && !dbg_enter);
        assert(auth_ex_pc_o == ex_pc && auth_issuing_o && auth_priv_o == csr_priv &&
               auth_virt_o == csr_virt);
    end
    always @* begin
        assert(auth_trap_o == trap_req && auth_dbg_enter_o == dbg_enter);
    end
