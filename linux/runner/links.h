// Links opened into the app on Linux (links.cc): a circle's invite (ghostmsg://join/#c.…), someone's add-me link
// (ghostmsg://add/NAME#KEY, GMFB-34) and a relay's (ghostmsg://relay?a=…), as the Mac's AppDelegate and Windows'
// links.cpp hand them to lib/desktop/links.dart.
#ifndef RUNNER_LINKS_H_
#define RUNNER_LINKS_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// The action a link is handed over by, from the copy the desktop started to the one already running (or to itself).
#define LINKS_ACTION "open-link"

// Whether [arg] is one of the app's own links (ghostmsg:…).
gboolean links_is_link(const gchar* arg);

// Adds the "open-link" action to [application], which takes the link as a string: on the copy that is the one of its
// kind, so a second start's link reaches it.
void links_add_action(GApplication* application);

// Answers lib/desktop/links.dart on "ghost_desktop/links" from [view]'s engine: "take" gives the links that came
// before, then each is handed over as it comes ("open").
void links_attach(FlView* view);

#endif  // RUNNER_LINKS_H_
