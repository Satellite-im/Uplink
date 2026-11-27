// The popup: a thin view over the worker, drawn with the Glacier kit so it looks like the app (Matt, 2026-11-21:
// "Rebuild the chrome extension UI ... to use glacier UI kit so it matches the app and remove the bottom recovery seed
// area only allow logging in with the standard method"). It sends typed messages and renders the status the worker
// returns; the worker holds the account and does the crypto and syncing.
import { Button, Callout, Card, Checkbox, Field, Heading, Input, List, ListItem, Pill, Row, Stack, Text } from '@glacier/react';
import { StrictMode, useEffect, useState, type FormEvent } from 'react';
import { createRoot } from 'react-dom/client';

interface ServiceStatus {
  id: string;
  name: string;
  signInUrl: string;
  ready: boolean;
  missing: string[];
  synced: boolean;
  syncedAt: number | null;
}
interface Status {
  signedIn: boolean;
  google?: { synced: boolean; syncedAt: number | null; open: boolean; incognito: boolean };
  address: string | null;
  username: string | null;
  services: ServiceStatus[];
  error?: string;
  note?: string;
  needsCode?: boolean;
}
type Said = { text: string; tone: 'danger' | 'success' | 'info' } | null;

const send = (msg: Record<string, unknown>): Promise<Status> => chrome.runtime.sendMessage(msg) as Promise<Status>;

function when(at: number | null): string {
  if (!at) return '';
  const mins = Math.round((Date.now() - at) / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins} min ago`;
  const hrs = Math.round(mins / 60);
  if (hrs < 24) return `${hrs} h ago`;
  return `${Math.round(hrs / 24)} d ago`;
}

function Popup() {
  const [status, setStatus] = useState<Status | null>(null);
  const [said, setSaid] = useState<Said>(null);
  const [busy, setBusy] = useState(false);

  /** Runs [run] against the worker and shows what it answers; [ok] is said where it worked. */
  async function act(run: () => Promise<Status>, ok?: string): Promise<Status | null> {
    setBusy(true);
    setSaid(null);
    try {
      const s = await run();
      setStatus(s);
      if (s.error) setSaid({ text: s.error, tone: 'danger' });
      else if (ok) setSaid({ text: ok, tone: 'success' });
      else if (s.note) setSaid({ text: s.note, tone: 'info' });
      return s;
    } catch (e) {
      setSaid({ text: (e as Error).message || 'Something went wrong.', tone: 'danger' });
      return null;
    } finally {
      setBusy(false);
    }
  }

  useEffect(() => {
    void act(() => send({ type: 'status-note' }));
  }, []);

  return (
    <Stack gap={4} className="popup" aria-live="polite">
      <Row justify="between" align="center">
        <Heading level={1} visualLevel={4} noMargin>
          Uplink keys
        </Heading>
        {status?.signedIn && (
          <Button variant="ghost" size="sm" disabled={busy} onClick={() => void act(() => send({ type: 'signOut' }))}>
            Sign out
          </Button>
        )}
      </Row>
      {status === null ? null : status.signedIn ? <SignedIn status={status} busy={busy} act={act} /> : <SignIn busy={busy} act={act} say={setSaid} />}
      {said && (
        <Callout tone={said.tone} role={said.tone === 'danger' ? 'alert' : 'status'}>
          {said.text}
        </Callout>
      )}
    </Stack>
  );
}

type Act = (run: () => Promise<Status>, ok?: string) => Promise<Status | null>;

/** Signing in to the Uplink account: username and password, and a texted code where the account has a verified
 *  number. The recovery words are not offered here. */
function SignIn({ busy, act, say }: { busy: boolean; act: Act; say: (s: Said) => void }) {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [needsCode, setNeedsCode] = useState(false);
  const [number, setNumber] = useState('');
  const [code, setCode] = useState('');
  const [stay, setStay] = useState(false);

  async function signIn(e: FormEvent) {
    e.preventDefault();
    if (!username.trim() || !password) return say({ text: 'Enter your username and password.', tone: 'danger' });
    const s = await act(() =>
      send({ type: 'signInPassword', username: username.trim(), password, code: code.trim() || undefined, number: number.trim() || undefined, stay }),
    );
    if (s?.needsCode) setNeedsCode(true);
  }

  function textCode() {
    if (!username.trim()) return say({ text: 'Enter your username first.', tone: 'danger' });
    if (!number.trim()) return say({ text: 'Enter the phone number on your account, with its country code.', tone: 'danger' });
    void act(() => send({ type: 'textCode', username: username.trim(), number: number.trim() }));
  }

  return (
    <form onSubmit={(e) => void signIn(e)}>
      <Stack gap={3}>
        <Text tone="muted" size="sm">
          Sign in with your Uplink account. Your sign-ins to other networks then sync, sealed, to every device on it.
        </Text>
        <Field label="Username">
          <Input value={username} onChange={(e) => setUsername(e.currentTarget.value)} autoComplete="username" autoCapitalize="none" spellCheck={false} />
        </Field>
        <Field label="Password">
          <Input type="password" value={password} onChange={(e) => setPassword(e.currentTarget.value)} autoComplete="current-password" />
        </Field>
        {needsCode && (
          <Card elevation={0} variant="wash">
            <Stack gap={3}>
              <Text size="sm" tone="muted">
                This account has a verified phone number: Uplink texts it a code before it lets you in.
              </Text>
              <Field label="That phone number">
                <Input type="tel" value={number} onChange={(e) => setNumber(e.currentTarget.value)} autoComplete="tel" placeholder="+1 555 010 0199" />
              </Field>
              <Button type="button" variant="outline" size="sm" disabled={busy} onClick={textCode}>
                Text me a code
              </Button>
              <Field label="Code texted to you">
                <Input value={code} onChange={(e) => setCode(e.currentTarget.value)} inputMode="numeric" autoComplete="one-time-code" />
              </Field>
            </Stack>
          </Card>
        )}
        <Checkbox label="Stay signed in on this computer" checked={stay} onCheckedChange={(v: boolean) => setStay(v)} />
        <Button type="submit" variant="solid" fullWidth loading={busy} disabled={busy}>
          Sign in
        </Button>
      </Stack>
    </form>
  );
}

/** Signed in: each network, whether this browser is signed in to it and whether it is synced; Google Messages apart. */
function SignedIn({ status, busy, act }: { status: Status; busy: boolean; act: Act }) {
  const g = status.google;
  return (
    <Stack gap={4}>
      <Text tone="muted" size="sm">
        Signed in as <b>{status.username ? `@${status.username}` : (status.address ?? 'your account')}</b>
      </Text>
      <Card elevation={1}>
        <List divided>
          {status.services.map((svc) => (
            <ListItem
              key={svc.id}
              title={svc.name}
              description={
                <Pill size="sm" tone={svc.synced ? 'success' : svc.ready ? 'accent' : 'neutral'}>
                  {svc.synced ? `Synced · ${when(svc.syncedAt)}` : svc.ready ? 'Signed in here' : 'Not signed in here'}
                </Pill>
              }
              trailing={
                svc.ready ? (
                  <Row gap={2}>
                    <Button size="sm" variant="soft" disabled={busy} onClick={() => void act(() => send({ type: 'sync', serviceId: svc.id }), 'Synced.')}>
                      {svc.synced ? 'Re-sync' : 'Sync'}
                    </Button>
                    {svc.synced && (
                      <Button size="sm" variant="ghost" disabled={busy} onClick={() => void act(() => send({ type: 'forget', serviceId: svc.id }), 'Stopped syncing that network.')}>
                        Stop
                      </Button>
                    )}
                  </Row>
                ) : (
                  <Button size="sm" variant="outline" onClick={() => void chrome.tabs.create({ url: svc.signInUrl })}>
                    Sign in
                  </Button>
                )
              }
            />
          ))}
        </List>
      </Card>
      <Button variant="solid" fullWidth disabled={busy} onClick={() => void act(() => send({ type: 'sync' }), 'Captured and synced.')}>
        Capture &amp; sync all
      </Button>
      {g && (
        <Card elevation={1}>
          <Stack gap={3}>
            <Row justify="between" align="center">
              <Text weight="semibold">Google Messages (RCS)</Text>
              <Pill size="sm" tone={g.synced ? 'success' : g.open ? 'accent' : 'neutral'}>
                {g.synced ? `Synced · ${when(g.syncedAt)}` : g.open ? 'Waiting for sign-in' : 'Not set up'}
              </Pill>
            </Row>
            <Text size="sm" tone="muted">
              Signs in to Google in a private window and hands that sign-in to your devices, so setting up Google Messages in Uplink is one tap there (and
              the emoji on your phone). Nothing is read from this browser&apos;s own Google sign-in.
            </Text>
            {!g.incognito && (
              <Callout tone="warning">
                First, in chrome://extensions › Uplink keys › Details, turn on <b>Allow in Incognito</b>.
              </Callout>
            )}
            <Row gap={2}>
              <Button size="sm" variant="soft" disabled={busy} onClick={() => void act(() => send({ type: 'googleSetup' }))}>
                {g.synced ? 'Set up again' : 'Set up Google Messages'}
              </Button>
              {g.synced && (
                <Button size="sm" variant="ghost" disabled={busy} onClick={() => void act(() => send({ type: 'forget', serviceId: 'gmessages' }), 'Stopped syncing Google Messages.')}>
                  Stop syncing
                </Button>
              )}
            </Row>
          </Stack>
        </Card>
      )}
    </Stack>
  );
}

createRoot(document.getElementById('app')!).render(
  <StrictMode>
    <Popup />
  </StrictMode>,
);
