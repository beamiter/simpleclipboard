.PHONY: check rust-check vim-check installer-check help-tags

check: rust-check vim-check installer-check help-tags

rust-check:
	cargo fmt --all -- --check
	cargo clippy --locked --all-targets -- -D warnings
	cargo test --locked --all-targets
	cargo build --locked --release

vim-check:
	vim -Nu NONE -i NONE -n -es -S test/vim_smoke.vim

installer-check:
	bash -n install.sh test/install_args.sh test/tcp_e2e.sh
	bash test/install_args.sh

help-tags:
	vim -Nu NONE -i NONE -n -es -c 'helptags doc' -c 'qa!'
