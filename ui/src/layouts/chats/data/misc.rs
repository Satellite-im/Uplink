use kit::elements::input::SpecialCharsAction;

pub fn get_input_options() -> kit::elements::input::Options {
    // Set up validation options for the input field
    let group_name_validation_options = kit::elements::input::Validation {
        // The input should have a maximum length of 64
        max_length: Some(64),
        // The input should have a minimum length of 0
        min_length: Some(0),
        // The input should only contain alphanumeric characters
        alpha_numeric_only: true,
        // The input can contain any whitespace
        no_whitespace: false,
        // The input component validation is shared - if you need to allow just colons in, set this to true
        ignore_colons: false,
        // The input should allow any special characters
        // if you need special chars, just pass a vec! with each char necessary, mainly if alpha_numeric_only is true
        special_chars: Some((
            SpecialCharsAction::Allow,
            " .,!?_&+~(){}[]+-/*".chars().collect(),
        )),
    };

    // Set up options for the input field
    kit::elements::input::Options {
        // Enable validation for the input field with the specified options
        with_validation: Some(group_name_validation_options),
        clear_on_submit: false,
        clear_validation_on_submit: true,
        // Use the default options for the remaining fields
        ..Default::default()
    }
}
