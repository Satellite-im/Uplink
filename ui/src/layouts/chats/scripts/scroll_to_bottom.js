// returns for eval
// warning: if you need to scroll to message X but message X is part of a huge block of messages, all from the 
// same sender, then setting message to message.parentElement.parentElement.getElementsByClassName("time-ago")[0] will 
// scroll to the end of the message block, perhaps way past message X. 
//
// todo: detect if message.parentElement occurs immediately before the time-ago element in message.parentElement.parentElement 
// and only then scroll the time-ago element into view. 
var message = document.getElementById("$MESSAGE_ID");
message.scrollIntoView({ behavior: 'instant', block: 'end' });
return "done";