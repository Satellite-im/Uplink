const all_keybind_sections = document.querySelectorAll(".keybind-section");
all_keybind_sections.forEach((element) => {
    element.style.backgroundColor = "rgba(0,0,0, 0.75)";
});

const settings_keybind = document.getElementById('$SHORTCUT_PRESSED');
settings_keybind.scrollIntoView({ behavior: 'smooth', block: 'start' });
settings_keybind.style.backgroundColor = "var(--secondary)";

setTimeout(() => {
    settings_keybind.style.backgroundColor = "rgba(0,0,0, 0.75)";
}, 3000);