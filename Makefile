.PHONY: vim-async check rust-check vim-check vim-remote installer-check shell-check help-tags vim-core defcompile core-verify doc-check skip-rules-check

check: core-verify rust-check vim-async vim-check vim-remote installer-check shell-check help-tags defcompile vim-core doc-check skip-rules-check

vim-async:
	vim -Nu NONE -i NONE -n -es -S tests/vim_async.vim

rust-check:
	cargo fmt --all -- --check
	cargo clippy --locked --all-targets -- -D warnings
	cargo test --locked --all-targets
	cargo build --locked --release

vim-check:
	vim -Nu NONE -i NONE -n -es -V1test/vim-smoke.log -S test/vim_smoke.vim || { cat test/vim-smoke.log; exit 1; }

# The suite API other simple* plugins call (CopyText, LastCopy, PasteText) and
# the SimpleRemote-aware path commands.  SimpleRemote is never on the
# runtimepath: the test creates the buffer variables and the one global
# function those paths consult itself.
vim-remote:
	vim -Nu NONE -i NONE -n -es -S tests/vim_remote.vim

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
#
# These lines are vendored too.  They are the tail of this Makefile — nothing
# above the banner belongs to the bundle — and `.simplecore.manifest` records
# them as a `footer` fragment.  Until it did, they were the one bundle member
# copied by hand and hashed by nothing, so core-verify could not see them
# drift; nine plugins carried an installer in the same position.
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
#
# Whole files are plain `sha256sum -c` records.  A fragment — a run of lines
# inside a file the plugin itself owns, like this footer — is recorded as
# `footer <lines> <sha256>  <path>` and checked against the tail of <path>.
core-verify:
	@awk ' \
	  /^[[:space:]]*(\#|$$)/ { next } \
	  $$1 == "version" && NF == 2 && $$2 ~ /^[1-9][0-9]*$$/ { versions++; next } \
	  length($$1) == 64 && $$1 !~ /[^0-9a-f]/ && NF == 2 { files++; next } \
	  $$1 == "footer" && NF == 4 && $$2 ~ /^[1-9][0-9]*$$/ \
	    && length($$3) == 64 && $$3 !~ /[^0-9a-f]/ { footers++; next } \
	  { bad = 1 } \
	  END { if (bad || versions != 1 || files == 0 || footers != 1) { \
	    print ".simplecore.manifest: invalid or incomplete bundle records" > "/dev/stderr"; exit 1 } } \
	' .simplecore.manifest
	@records=$$(grep -cE '^[0-9a-f]{64}' .simplecore.manifest); \
	checked=$$(grep -cE '^[0-9a-f]{64}  ' .simplecore.manifest); \
	test "$$records" = "$$checked" || { \
	  echo ".simplecore.manifest: $$((records - checked)) hash record(s) not checked" >&2; \
	  echo "  a record whose separator is not exactly two spaces is dropped by the" >&2; \
	  echo "  reader below and would verify green while its file went unchecked." >&2; \
	  exit 1; }
	@grep -E '^[0-9a-f]{64}  ' .simplecore.manifest | sha256sum -c --quiet
	@awk '$$1 == "footer" { print $$2, $$3, $$4 }' .simplecore.manifest \
	| while read -r lines sum path; do \
		test -f "$$path" && fragment=$$(tail -n "$$lines" "$$path") || exit 1; \
		test "$$(printf '%s\n' "$$fragment" | sha256sum | cut -d' ' -f1)" = "$$sum" \
		|| { echo "$$path: FAILED (simplecore footer)" >&2; exit 1; }; \
	done
	@echo "simplecore: bundle v$$(awk '$$1 == "version" { print $$2 }' .simplecore.manifest) verified"

# core-verify proves this repository is internally consistent: every vendored
# copy still matches the manifest written beside it.  It cannot prove freshness.
# A plugin that misses a re-vendor keeps verifying its own stale copy for ever,
# and stays green doing it, because the bundle is deliberately not required to
# be present for the build to work.  This target is the other half, for when it
# is present; `check` cannot depend on it without making the bundle a build
# dependency, which is the coupling the vendoring exists to avoid.
SIMPLECORE_DIR ?= ../.simplecore
core-fresh:
	@if [ -x "$(SIMPLECORE_DIR)/vendor.sh" ]; then \
	  SIMPLECORE_SUITE="$(patsubst %/,%,$(dir $(CURDIR)))" \
	    "$(SIMPLECORE_DIR)/vendor.sh" --check "$(notdir $(CURDIR))"; \
	else \
	  echo "simplecore: $(SIMPLECORE_DIR) is not checked out; freshness unverified"; \
	fi

# Supervisor regression suite: liveness, generation guards, backoff restarts,
# the crash-loop breaker, request timeouts, and both outcomes of the protocol
# handshake — the reply that lands, and the deadline that expires and fails the
# start.
vim-core:
	vim -Nu NONE -n -i NONE -es -S tests/vim_core.vim

# Vim9 compiles def bodies lazily, so a type error in a cold branch stays
# hidden until a user reaches it.  :defcompile surfaces it here instead.
defcompile:
	vim -Nu NONE -n -i NONE -es -S tests/defcompile.vim

.PHONY: core-verify core-fresh vim-core defcompile
