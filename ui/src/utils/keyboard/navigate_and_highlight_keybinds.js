const all_keybind_sections = document.querySelectorAll(".keybind-section");
all_keybind_sections.forEach((element) => {
    element.classList.remove("highlight");
});

const settings_keybind = document.getElementById('$SHORTCUT_PRESSED');
settings_keybind.scrollIntoView({ behavior: 'smooth', block: 'start' });
settings_keybind.classList.add("highlight");

setTimeout(() => {
    settings_keybind.classList.remove("highlight");
}, 3000);