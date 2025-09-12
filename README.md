# Simple Vim9 Plugin with Rust Backend

A demonstration plugin showing how to create modern Vim plugins using Vim9 script with a high-performance Rust backend.

## Features

- **Text Transformation**: Uppercase, lowercase, capitalize, title case
- **Text Operations**: Reverse strings, normalize whitespace
- **Statistics**: Count words, characters, check palindromes
- **Selection Support**: Process visually selected text
- **Batch Operations**: Apply transformations to entire buffer
- **Dual Backend**: Rust for performance, Vim fallbacks for compatibility
- **Modern Vim9**: Uses latest Vim9 script features

## Requirements

- Vim 9.0+ with `vim9script` support
- Rust toolchain (for building the backend)

## Installation

### Using vim-plug

```vim
Plug 'username/simple-vim9-plugin', { 'do': 'cargo build --release' }
# simpleclipboard
