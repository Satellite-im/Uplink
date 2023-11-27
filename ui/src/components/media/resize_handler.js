let call_info = document.getElementsByClassName("call-info")[0]
let group = call_info.getElementsByClassName("calling-users")[0]
addEventListener("resize", (event) => {
    checkAmount()
});

function checkAmount() {
    let total_width = call_info.getBoundingClientRect().width - 4
    let user_1 = call_info.getElementsByClassName("call-user")[0]
    let user_2 = call_info.getElementsByClassName("call-user")[1]
    if (user_1 && user_2) {
        let computed_width = user_2.getBoundingClientRect().left - user_1.getBoundingClientRect().left
        let amount = total_width / computed_width
        dioxus.send(amount)
    }
}

checkAmount()