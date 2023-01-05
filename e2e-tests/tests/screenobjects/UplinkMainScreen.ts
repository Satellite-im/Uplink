import AppScreen from "./AppScreen"

const SELECTORS = {
  BUTTON: "~button",
  BUTTON_NAV: "~button-nav",
  CHAT_SEARCH_INPUT: "~chat-search-input",
  PRE_RELEASE_INDICATOR: "~pre-release",
  PRE_RELEASE_INDICATOR_TEXT: "-ios class chain:**/XCUIElementTypeStaticText[`value == \"Pre-release\"`]",
  SIDEBAR: "~sidebar",
  SIDEBAR_CHILDREN: "~sidebar-children",
  SIDEBAR_SEACH: "~sidebar-search",
  SKELETAL_USER: "~skeletal-user",
  WELCOME_SCREEN: "~welcome-screen",
  WINDOW: "-ios class chain:**/XCUIElementTypeWebView",
}

class UplinkMainScreen extends AppScreen {
  constructor() {
    super(SELECTORS.WELCOME_SCREEN)
  }

  get button() {
    return $(SELECTORS.BUTTON)
  }

  get buttonAddSomeone() {
    return $(SELECTORS.WELCOME_SCREEN).$(SELECTORS.BUTTON)
  }

  get buttonNav() {
    return $(SELECTORS.BUTTON_NAV)
  }

  get buttonNavChat() {
    return $(SELECTORS.BUTTON_NAV).$$(SELECTORS.BUTTON)[0]
  }

  get buttonNavFiles() {
    return $(SELECTORS.BUTTON_NAV).$$(SELECTORS.BUTTON)[1]
  }

  get buttonNavFriends() {
    return $(SELECTORS.BUTTON_NAV).$$(SELECTORS.BUTTON)[2]
  }

  get buttonNavSettings() {
    return $(SELECTORS.BUTTON_NAV).$$(SELECTORS.BUTTON)[3]
  }

  get chatSearchInput() {
    return $(SELECTORS.CHAT_SEARCH_INPUT)
  }

  get prereleaseIndicator() {
    return $(SELECTORS.PRE_RELEASE_INDICATOR)
  }

  get prereleaseIndicatorText() {
    return $(SELECTORS.PRE_RELEASE_INDICATOR_TEXT)
  }

  get sidebar() {
    return $(SELECTORS.SIDEBAR)
  }

  get sidebarChildren() {
    return $(SELECTORS.SIDEBAR_CHILDREN)
  }

  get sidebarSearch() {
    return $(SELECTORS.SIDEBAR_SEACH)
  }

  get skeletalUser() {
    return $$(SELECTORS.SKELETAL_USER)
  }

  get welcomeScreen() {
    return $(SELECTORS.WELCOME_SCREEN)
  }

  get window() {
    return $(SELECTORS.WINDOW)
  }
}

export default new UplinkMainScreen()
