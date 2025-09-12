cargo build --release
mkdir lib
cp target/release/libsimpleclipboard.so ~/.vim/plugged/simpleclipboard/lib/
cp target/release/simpleclipboard-daemon ~/.vim/plugged/simpleclipboard/lib/
