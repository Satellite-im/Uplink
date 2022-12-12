use glob::glob;

use std::{
    error::Error,
    fs::{self, File},
    io::Write,
};

use rsass::{compile_scss, output};

fn main() -> Result<(), Box<dyn Error>> {
    let scss_output = "./src/compiled_styles.css";
    let mut scss = File::create(scss_output)?;

    let mut contents = String::from("");
    for entry in glob("src/**/*.scss").expect("Failed to read glob pattern") {
        let path = entry?;
        let data = fs::read_to_string(path)?;
        contents += data.as_ref();
    }

    contents += "/*! Generated automatically, don't edit this file or your work will be lost. */";

    let format = output::Format {
        style: output::Style::Compressed,
        ..Default::default()
    };

    let css = compile_scss(contents.as_bytes(), format)?;

    scss.write_all(&css)?;
    scss.flush()?;

    Ok(())
}
