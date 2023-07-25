pub struct ExtensionsAPI {
    pub version: &'static str,
    pub rustc_version: &'static str,
    pub cargo_version: &'static str,
}

/// Extensions API base
impl ExtensionsAPI {
    pub fn get_version(&self) -> &'static str {
        self.version
    }

    pub fn get_rustc_version(&self) -> &'static str {
        self.rustc_version
    }

    pub fn get_cargo_version(&self) -> &'static str {
        self.cargo_version
    }
}

/// Emoji's
impl ExtensionsAPI {
    pub fn dispatch_emoji(&self) {
        // does this extension have the emoji permissions
        // access state
        // where is the destination?
        // send to chatbar
        // send to message by uuid as reaction
    }
}
