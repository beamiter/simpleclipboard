.PHONY: check rust-check vim-check installer-check shell-check help-tags vim-core defcompile core-verify doc-check skip-rules-check

check: core-verify rust-check vim-check installer-check shell-check help-tags defcompile vim-core doc-check skip-rules-check

rust-check:
	cargo fmt --all -- --check
	cargo clippy --locked --all-targets -- -D warnings
	cargo test --locked --all-targets
	cargo build --locked --release

vim-check:
	vim -Nu NONE -i NONE -n -es -S test/vim_smoke.vim

installer-check:
	bash -n install.sh test/install_args.sh test/tcp_e2e.sh \
	  test/e2e_skip_rules.sh test/e2e_skip_rules_test.sh test/doc_claims.sh
	bash test/install_args.sh

# Prose is the one part of the repo nothing else checks: it compiles under no
# compiler and runs in no test, so a sentence describing a feature reads the
# same whether or not the feature exists.  This target is the grep that keeps
# the documented commands, helper programs and caveats tied to the code.
doc-check:
	bash test/doc_claims.sh

# test/tcp_e2e.sh needs a built daemon and a live port, so `make check` cannot
# run it; the rule deciding when it may downgrade a failed clipboard round trip
# to a skip needs neither, and is the part most likely to hide a regression.
skip-rules-check:
	bash test/e2e_skip_rules_test.sh

# shellcheck is not needed to work on the plugin, so its absence skips instead
# of failing; CI installs it, which is what keeps this honest.  Having it here
# rather than only in the workflow is what lets CI run `make check` alone.
shell-check:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck install.sh test/install_args.sh test/tcp_e2e.sh \
	    test/e2e_skip_rules.sh test/e2e_skip_rules_test.sh test/doc_claims.sh; \
	else \
	  echo "shellcheck: not installed; skipped"; \
	fi

help-tags:
	vim -Nu NONE -i NONE -n -es -c 'helptags doc' -c 'qa!'

# ---------------------------------------------------------------------------
# simplecore: the vendored daemon supervisor shared by the simple* suite.
#   https://github.com/beamiter/simplecore
# Regenerate with ../.simplecore/vendor.sh; never edit autoload/simpleclipboard/core.vim.
# ---------------------------------------------------------------------------

# The bundle is copied into each plugin rather than shared by reference, so
# that every plugin stays independently installable.  Copies drift silently
# unless something checks them, and one such copy went unnoticed long enough
# for the whole .simplecore directory to go missing before it had a repository
# of its own: .simplecore.manifest pins the sha256 of every vendored file, and
# this target fails the build when a copy no longer matches.
#
#   git clone https://github.com/beamiter/simplecore ../.simplecore
#   ../.simplecore/vendor.sh --check    # suite-wide drift
#   ../.simplecore/vendor.sh            # re-vendor
core-verify:
	@grep -E '^[0-9a-f]{64}  ' .simplecore.manifest | sha256sum -c --quiet
	@echo "simplecore: bundle v$$(awk '$$1 == "version" { print $$2 }' .simplecore.manifest) verified"

# Supervisor regression suite: liveness, generation guards, backoff restarts,
# the crash-loop breaker, request timeouts and the protocol handshake.
vim-core:
	vim -Nu NONE -n -i NONE -es -S tests/vim_core.vim

# Vim9 compiles def bodies lazily, so a type error in a cold branch stays
# hidden until a user reaches it.  :defcompile surfaces it here instead.
defcompile:
	vim -Nu NONE -n -i NONE -es -S tests/defcompile.vim
