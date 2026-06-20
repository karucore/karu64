# test/act4-karu/env.sh
#
#   source test/act4-karu/env.sh
#
# Puts the ACT4 toolchain on PATH and points the udb gem at a writable
# vendor dir. The `act` framework (a Python venv at ~/act-venv) shells out
# to `bundle`/`udb` (Ruby) and to `sail_riscv_sim`; this wires all three up.
#
# Rebuilt 2026-05-25 after the original install was lost:
#   - act:           pip-editable venv at ~/act-venv
#   - Ruby:          3.3.11 via rbenv (the udb gem needs Ruby >= 3.2; the
#                    system ruby is only 3.1)
#   - sail_riscv_sim: built from $RVSRC/sail-riscv, installed to ~/.local/bin

# --- Ruby 3.3.11 via rbenv (udb requires >= 3.2) ---
# Use the shims dir + RBENV_VERSION directly instead of `rbenv init`, which
# emits `source ...` (dash, used by make recipes, has no `source`).
export RBENV_VERSION="3.3.11"
export PATH="$HOME/.rbenv/versions/$RBENV_VERSION/bin:$HOME/.rbenv/shims:$HOME/.rbenv/bin:$PATH"
RUBY_ABI="3.3.0"

UDB_VENDOR="$HOME/.local/share/bundler-act/ruby/$RUBY_ABI"

_add_path() { case ":$PATH:" in *":$1:"*) ;; *) export PATH="$1:$PATH" ;; esac; }

_add_path "$HOME/act-venv/bin"		# the `act` CLI (pip-editable venv)
_add_path "$HOME/.local/bin"		# sail_riscv_sim
_add_path "$UDB_VENDOR/bin"

# Keep the udb gem + its deps in a private vendor dir (writable).
export GEM_HOME="$UDB_VENDOR"
export GEM_PATH="$UDB_VENDOR"
