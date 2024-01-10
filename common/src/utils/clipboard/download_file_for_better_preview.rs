pub fn download_file_for_better_preview(file_name: String) {
    let file_name_with_extension = format!("{}", cx.props.filename);
    let temp_dir = STATIC_ARGS.temp_files.join(file_name_with_extension);
    if !temp_dir.exists() {
        cx.props.on_press.call(Some(temp_dir.clone()));
    }
    let temp_path_as_string = temp_dir.clone().to_string_lossy().to_string();
}
