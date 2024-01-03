use common::language::get_local_text;
use dioxus_desktop::tao;
use dioxus_desktop::LogicalSize;
use tao::window::WindowBuilder;

pub fn get_window_builder(with_predefined_size: bool) -> WindowBuilder {
    let title = get_local_text("uplink");

    #[allow(unused_mut)]
    let mut window = WindowBuilder::new()
        .with_title(title)
        .with_resizable(true)
        // We start the min inner size smaller because the prelude pages like unlock can be rendered much smaller.
        .with_min_inner_size(LogicalSize::new(300.0, 350.0));

    if with_predefined_size {
        window = window.with_inner_size(LogicalSize::new(950.0, 600.0));
    }

    #[cfg(target_os = "macos")]
    {
        use dioxus_desktop::tao::platform::macos::WindowBuilderExtMacOS;

        window = window
            .with_has_shadow(true)
            .with_transparent(true)
            .with_fullsize_content_view(true)
            .with_titlebar_transparent(true)
            .with_title("")
    }

    #[cfg(not(target_os = "macos"))]
    {
        window = window.with_decorations(false).with_transparent(true);
    }
    window
}
