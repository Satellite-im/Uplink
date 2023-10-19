// returns for eval
var message = document.getElementById("$MESSAGE_ID");
var time = message.parentElement.parentElement.getElementsByClassName("time-ago")[0];
// try find the time-ago element
if (time) {
    message = time;
}
message.scrollIntoView({ behavior: 'instant', block: 'end' });
return "done";