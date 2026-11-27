import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../kit/settings_type.dart';
import 'common.dart';

/// How to run the Google Messages helper on a Mac or a Windows PC, kept running (Matt, 2026-11-15: "Tell me how to
/// setup the sidecar on mac and PC in a guide found in settings I'll habe it run on my PC always"). In Settings ›
/// Messages on the phone and Settings › Google Messages on a computer.
///
/// The helper is in Uplink for Mac and for Windows (sidecar/gmessages): nothing to install apart from the app.
/// Google Messages keeps one web session at a time, so where the phone runs its own connection (lib/ui/gm_web_screen.dart)
/// it holds the session and the computer shows the same conversations through the phone.
class GmGuideScreen extends StatelessWidget {
  const GmGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    Widget heading(String s) => Padding(
          padding: EdgeInsets.only(top: t.space(6), bottom: t.space(2)),
          child: Text(s, style: pageText(t, t.fontSize('lg'), weight: 'bold', color: t.color('app-ink'))),
        );
    Widget para(String s) => Padding(
          padding: EdgeInsets.only(bottom: t.space(3)),
          child: Text(s, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.5)),
        );
    Widget step(int n, String s) => Padding(
          padding: EdgeInsets.only(bottom: t.space(3)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: t.lenOf('1.5rem'),
              height: t.lenOf('1.5rem'),
              margin: EdgeInsetsDirectional.only(end: t.space(3)),
              decoration: BoxDecoration(shape: BoxShape.circle, color: t.color('app-ink')),
              alignment: Alignment.center,
              child: Text('$n', style: pageText(t, t.fontSize('xs'), weight: 'bold', color: t.color('app-paper'))),
            ),
            Expanded(child: Text(s, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink'), height: 1.5))),
          ]),
        );
    Widget box(LucideIcon icon, String title, String s) => Container(
          margin: EdgeInsets.only(bottom: t.space(3)),
          padding: EdgeInsets.all(t.space(4)),
          decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.radius('lg')), border: Border.all(color: t.color('app-rule'))),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: EdgeInsetsDirectional.only(end: t.space(3), top: 2), child: AppIcon(icon, size: 18)),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: t.color('app-ink'))),
                SizedBox(height: t.space(1)),
                Text(s, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.5)),
              ]),
            ),
          ]),
        );
    return GhostPage(
      title: 'Google Messages on a computer',
      body: ListView(padding: EdgeInsetsDirectional.fromSTEB(t.space(4), 0, t.space(4), t.space(10)), children: [
        para('Uplink for Mac and Windows has a helper built in that connects to Google Messages the way messages.google.com does. Paired once, the computer shows every Google Messages conversation, RCS and texts, with their history, pictures and reactions, and sends through it. Nothing else to install.'),
        box(LucideMore.smartphone, 'Or no computer at all', 'Your phone can run the same connection itself: Settings › Messages › Google Messages connection on the phone. Then nothing needs to stay on, and the computer shows everything through your phone whenever it is open.'),
        heading('1. Get the app'),
        step(1, 'On the computer, go to gogho.st and download Uplink for Mac or for Windows. Install it and open it.'),
        step(2, 'Pair it with your phone when it asks: the computer shows a code, and you scan it from Settings › Computers on your phone. This links the computer to your texts.'),
        heading('2. Pair Google Messages'),
        step(1, 'On the computer, open Settings › Google Messages. It walks you through the rest, in one place.'),
        step(2, 'It opens a Google sign-in in a private (incognito) window: sign in with the Google account Google Messages on your phone uses.'),
        step(3, 'Copy that page\'s request from the browser\'s developer tools (Network, the request named config, Copy as cURL) and paste it into Uplink.'),
        step(4, 'Google Messages on your phone asks you to tap an emoji: tap the one Uplink shows. Then close the private window (don\'t sign out in it). The computer says Connected, and Google Messages lists it under Device pairing.'),
        para('Google has replaced Device pairing\'s QR code with this Google-account pairing where Google Messages is signed in to an account. If yours still offers a QR code scanner, Pair with a QR code instead is on the same page.'),
        heading('3. Keep it running'),
        para('The helper runs while Uplink is open. Closing the window quits it; minimise it instead.'),
        box(Lucide.laptop, 'Windows: start with Windows', 'Press Windows+R, type shell:startup and press Enter. In the folder that opens, right-click, choose New › Shortcut, and point it at Ghost Messaging (in %LOCALAPPDATA%\\Programs\\Ghost Messaging). Ghost then opens when you sign in. In Power options, keep the PC from sleeping if it should answer all day.'),
        box(Lucide.laptop, 'Mac: open at login', 'Open System Settings › General › Login Items, press + under Open at Login, and choose Uplink from Applications. Keep the Mac awake (System Settings › Energy) if it should answer while you are away.'),
        heading('Good to know'),
        para('Google Messages keeps one web session at a time. If your phone runs its own connection, the phone holds it and the computer shows the same conversations through the phone. If messages.google.com is opened somewhere, it takes the session for a while; Uplink takes it back.'),
        para('Your phone needs to be on and online: Google Messages sends everything through it. The connection goes between the computer and Google only, never through Uplink\'s servers.'),
        para('The helper is open source under the GNU AGPL, built on mautrix-gmessages: github.com/InfamousVague/ghost-gmessages-sidecar.'),
      ]),
    );
  }
}
