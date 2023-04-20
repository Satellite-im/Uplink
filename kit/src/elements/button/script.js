(() => {
    const button_SAFE_UUID = document.getElementById("DIUU");
    const tooltip_SAFE_UUID = document.getElementById("tooltip-DIUU");

    if (button_SAFE_UUID != null && tooltip_SAFE_UUID != null) {
        button_SAFE_UUID.addEventListener("mouseover", function() {
            tooltip_SAFE_UUID
                .classList.remove("hidden");
            tooltip_SAFE_UUID
                .classList.add("visible");
        });

        button_SAFE_UUID.addEventListener("mouseout", function() {
            tooltip_SAFE_UUID
                .classList.remove("visible");
            tooltip_SAFE_UUID
                .classList.add("hidden");
        });
    }
})()