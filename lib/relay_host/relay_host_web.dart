import 'hosting.dart';

/// A relay hosted from the app, in a browser (lib/relay_host/relay_host.dart): there is none. A page can't listen for
/// others, and runs only while it is open in a tab; it can still use a relay hosted from someone's app on the local
/// network, as any relay. Nothing makes one here.
RelayHosting? makeRelayHost() => null;
