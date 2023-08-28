function filterList() {
    var userList = document.getElementById('userList');
    var searchValue = "$SEARCH_TYPED_CHARS";
  
    var listItems = userList.getElementsByTagName('li');
    for (const item of listItems) {
      const userName = item.innerText.toLowerCase();
      if (userName.includes(searchValue)) {
        // Highlight the matching part of the name
        const index = userName.indexOf(searchValue);
        const highlightedName =
          userName.slice(0, index) +
          '<span class="highlight">' +
          userName.slice(index, index + searchValue.length) +
          '</span>' +
          userName.slice(index + searchValue.length);
  
        item.innerHTML = highlightedName;
      } else {
        // Remove highlighting if there's no match
        item.innerHTML = item.innerText;
      }
    }
  }