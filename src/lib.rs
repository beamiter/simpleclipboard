use std::ffi::CStr;
use std::os::raw::{c_char, c_int};

/// 设置系统剪贴板文本（返回 1 成功，0 失败）
/// - Linux 下 arboard 会在 X11/Wayland 间自动工作（依赖 DISPLAY/WAYLAND_DISPLAY 环境）
/// - 输入作为 UTF-8 处理；如果不是严格 UTF-8，使用 lossy 转换避免报错
#[unsafe(no_mangle)]
pub extern "C" fn rust_set_clipboard(input: *const c_char) -> c_int {
    if input.is_null() {
        return 0;
    }

    let text: String = unsafe {
        // 尽量容忍非 UTF-8，避免直接失败
        CStr::from_ptr(input).to_string_lossy().into_owned()
    };

    match arboard::Clipboard::new().and_then(|mut cb| cb.set_text(text)) {
        Ok(_) => 1,
        Err(_) => 0,
    }
}
