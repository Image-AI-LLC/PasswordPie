// The toolbar popup: open PasswordPie, the passwordpie.com account, Premium, and a key to redeem. What it says is in
// docs/UX.md, "Premium in the browser". Everything it reaches goes through `PopupApi`, so tests can drive it.
import { QueryClient, QueryClientProvider, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useState, type ReactNode } from 'react';
import type { Entitlement, EntitlementResult, RedeemResult } from '../lib/account';
import type { AccountUser, SignInResult } from '../lib/auth';
import type { AppPremium } from '../lib/pass-relay';
import type { PopupStatus } from '../lib/protocol';
import { SCAN_MESSAGES, type ScanOutcome } from '../lib/scan-outcome';

export interface PopupApi {
  /** False in the App Store build: no upgrade link and no key field. */
  sellsPremium: boolean;
  /** False in the App Store build, which has no account at all: no sign-in, and nothing asks passwordpie.com. */
  accountEnabled: boolean;
  googleAvailable: boolean;
  openPanel(): Promise<void>;
  /** The shortcut Chrome actually gave `open-panel`, such as "⌥⇧P"; "" when it gave none (the key was taken). */
  panelShortcut(): Promise<string>;
  status(): Promise<PopupStatus>;
  /** "Scan QR code on this page": the background reads the tab's two-step QR code and hands it to the app. */
  scanPage(): Promise<ScanOutcome>;
  /** Hands the app the account's pass now, and says whether the app on this Mac has it. */
  appPremium(): Promise<AppPremium>;
  user(): Promise<AccountUser | null>;
  /** What was kept from the last answer, shown at once. */
  cachedEntitlement(): Promise<Entitlement | null>;
  refreshEntitlement(): Promise<EntitlementResult>;
  signIn(email: string, password: string): Promise<SignInResult>;
  signUp(name: string, email: string, password: string): Promise<SignInResult>;
  signInWithGoogle(): Promise<SignInResult>;
  signOut(): Promise<void>;
  redeem(code: string): Promise<RedeemResult>;
  openUrl(url: string): void;
  upgradeUrl?: string;
  signUpUrl: string;
  forgotPasswordUrl: string;
}

const REDEEM_MESSAGES: Record<string, string> = {
  invalid: 'That key is not valid. Keys look like PPIE-XXXX-XXXX-XXXX.',
  used: 'That key was already used.',
  expired: 'That key has expired.',
  'rate-limited': 'Too many tries. Wait a minute and try again.',
  'signed-out': 'Sign in again to redeem a key.',
  network: 'Could not reach passwordpie.com.',
  server: 'passwordpie.com could not redeem it right now.',
};

const PLAN_NAMES: Record<string, string> = { lifetime: 'Lifetime', yearly: 'Yearly', key: 'Key' };

/** The one line about the Mac app, only when it does not have Premium from here. Nothing when it does. */
const APP_LINES: Record<string, string> = {
  unreachable: 'Open PasswordPie on this Mac to bring Premium to it.',
  refused: 'Update PasswordPie on this Mac to bring Premium to it.',
};

export function planLine(entitlement: Entitlement | null | undefined): string {
  if (!entitlement?.premium) return 'Free';
  const plan = entitlement.plan ? PLAN_NAMES[entitlement.plan] : undefined;
  const until = entitlement.expiresAt ? new Date(entitlement.expiresAt) : undefined;
  const date = until && !Number.isNaN(until.getTime()) ? until.toLocaleDateString(undefined, { dateStyle: 'medium' }) : undefined;
  return ['Premium', plan, date ? `until ${date}` : undefined].filter(Boolean).join(' · ');
}

function Button(props: {
  children: ReactNode;
  onClick?: () => void;
  kind?: 'primary' | 'secondary' | 'link';
  type?: 'button' | 'submit';
  disabled?: boolean;
  big?: boolean;
}) {
  const kind = props.kind ?? 'secondary';
  const base = 'inline-flex items-center justify-center gap-2 rounded-lg font-medium transition disabled:opacity-50 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-pp-focus';
  const look =
    kind === 'primary'
      ? 'bg-pp-accent text-pp-on-accent hover:brightness-105 active:brightness-95'
      : kind === 'link'
        ? 'text-pp-accent-text hover:underline'
        : 'border border-pp-border bg-pp-field text-pp-text hover:bg-pp-surface';
  const size = kind === 'link' ? 'text-[13px]' : props.big ? 'h-11 px-4 text-[15px] w-full' : 'h-8 px-3 text-[13px]';
  return (
    <button type={props.type ?? 'button'} className={`${base} ${look} ${size}`} onClick={props.onClick} disabled={props.disabled}>
      {props.children}
    </button>
  );
}

function Field(props: { label: string; type?: string; value: string; onChange: (v: string) => void; autoComplete?: string; placeholder?: string }) {
  return (
    <label className="flex flex-col gap-1 text-[12px] text-pp-text-secondary">
      {props.label}
      <input
        className="h-8 rounded-md border border-pp-border bg-pp-field px-2 text-[13px] text-pp-text caret-pp-focus outline-none focus:border-pp-focus"
        type={props.type ?? 'text'}
        value={props.value}
        autoComplete={props.autoComplete}
        placeholder={props.placeholder}
        onChange={(e) => props.onChange(e.target.value)}
      />
    </label>
  );
}

function SignIn({ api }: { api: PopupApi }) {
  const client = useQueryClient();
  const [mode, setMode] = useState<'sign-in' | 'sign-up'>('sign-in');
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const done = async (result: SignInResult) => {
    if (result.ok) {
      await api.refreshEntitlement();
      await client.invalidateQueries();
    }
    return result;
  };
  const submit = useMutation({
    mutationFn: async () => done(mode === 'sign-in' ? await api.signIn(email, password) : await api.signUp(name, email, password)),
  });
  const google = useMutation({ mutationFn: async () => done(await api.signInWithGoogle()) });
  const error = [submit.data, google.data].find((r) => r && !r.ok) as { ok: false; message: string } | undefined;
  const onSubmit = (e: { preventDefault(): void }) => {
    e.preventDefault();
    submit.mutate();
  };
  return (
    <form className="flex flex-col gap-2" onSubmit={onSubmit} aria-label={mode === 'sign-in' ? 'Sign in' : 'Create account'}>
      <p className="text-[13px] text-pp-text-secondary">
        Sign in with your PasswordPie account to fill two-step codes in the browser with Premium.
      </p>
      {mode === 'sign-up' && <Field label="Name" value={name} onChange={setName} autoComplete="name" />}
      <Field label="Email" type="email" value={email} onChange={setEmail} autoComplete="username" />
      <Field
        label="Password"
        type="password"
        value={password}
        onChange={setPassword}
        autoComplete={mode === 'sign-in' ? 'current-password' : 'new-password'}
      />
      {error && (
        <p role="alert" className="text-[12px] text-pp-error">
          {error.message}
        </p>
      )}
      <div className="flex items-center gap-2">
        <Button kind="primary" type="submit" disabled={submit.isPending || !email || !password}>
          {mode === 'sign-in' ? 'Sign In' : 'Create Account'}
        </Button>
        {api.googleAvailable && (
          <Button onClick={() => google.mutate()} disabled={google.isPending}>
            Continue with Google
          </Button>
        )}
      </div>
      <div className="flex gap-3">
        <Button kind="link" onClick={() => setMode(mode === 'sign-in' ? 'sign-up' : 'sign-in')}>
          {mode === 'sign-in' ? 'Create an account' : 'I have an account'}
        </Button>
        {mode === 'sign-in' && (
          <Button kind="link" onClick={() => api.openUrl(api.forgotPasswordUrl)}>
            Forgot password?
          </Button>
        )}
      </div>
    </form>
  );
}

function Redeem({ api }: { api: PopupApi }) {
  const client = useQueryClient();
  const [code, setCode] = useState('');
  const redeem = useMutation({
    mutationFn: () => api.redeem(code),
    onSuccess: async (result) => {
      if (result.ok) {
        setCode('');
        client.setQueryData(['entitlement'], result.entitlement);
      }
    },
  });
  const failed = redeem.data && !redeem.data.ok ? REDEEM_MESSAGES[redeem.data.reason] : undefined;
  return (
    <form
      className="flex flex-col gap-1"
      aria-label="Redeem a key"
      onSubmit={(e) => {
        e.preventDefault();
        redeem.mutate();
      }}
    >
      <div className="flex items-end gap-2">
        <div className="flex-1">
          <Field label="Have a key?" value={code} onChange={setCode} placeholder="PPIE-XXXX-XXXX-XXXX" />
        </div>
        <Button type="submit" disabled={redeem.isPending || !code.trim()}>
          Redeem
        </Button>
      </div>
      {failed && (
        <p role="alert" className="text-[12px] text-pp-error">
          {failed}
        </p>
      )}
    </form>
  );
}

function Account({ api, user }: { api: PopupApi; user: AccountUser }) {
  const client = useQueryClient();
  const entitlement = useQuery({
    queryKey: ['entitlement'],
    queryFn: async () => {
      const result = await api.refreshEntitlement();
      if (result.ok) return result.entitlement;
      if (result.reason === 'signed-out') await client.invalidateQueries({ queryKey: ['user'] });
      return api.cachedEntitlement();
    },
  });
  const cached = useQuery({ queryKey: ['cached-entitlement'], queryFn: () => api.cachedEntitlement() });
  const current = entitlement.data ?? cached.data;
  const premium = current?.premium === true;
  // Asked again whenever the pass changes. Until the app answers, the popup claims nothing about it.
  const app = useQuery({ queryKey: ['app-premium', current?.token ?? null], queryFn: () => api.appPremium(), enabled: premium });
  const signOut = useMutation({
    mutationFn: () => api.signOut(),
    onSuccess: () => client.invalidateQueries(),
  });
  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center justify-between gap-2">
        <span className="truncate text-[13px] text-pp-text" title={user.email}>
          {user.email}
        </span>
        <Button kind="link" onClick={() => signOut.mutate()}>
          Sign Out
        </Button>
      </div>
      <div className="rounded-lg border border-pp-border bg-pp-field p-3">
        <p className="text-[14px] font-semibold text-pp-text" data-testid="plan">
          {planLine(current)}
        </p>
        <p className="mt-1 text-[13px] text-pp-text-secondary">
          {premium ? 'Two-step codes fill in the browser after the password.' : 'Two-step codes in the browser need Premium.'}
        </p>
        {premium && APP_LINES[app.data ?? ''] && (
          <p className="mt-1 text-[12px] text-pp-text-tertiary" data-testid="app-premium">
            {APP_LINES[app.data ?? '']}
          </p>
        )}
        {!premium && api.sellsPremium && api.upgradeUrl && (
          <div className="mt-2">
            <Button kind="primary" onClick={() => api.upgradeUrl && api.openUrl(api.upgradeUrl)}>
              Upgrade
            </Button>
          </div>
        )}
      </div>
      {!premium && api.sellsPremium && <Redeem api={api} />}
    </div>
  );
}

/** One button and the line it leaves. Runs only on a click. */
function ScanQr({ api }: { api: PopupApi }) {
  const scan = useMutation({ mutationFn: () => api.scanPage() });
  const outcome = scan.data;
  const named = outcome?.kind === 'sent' ? [outcome.issuer, outcome.account].filter(Boolean).join(' · ') : '';
  return (
    <div className="flex flex-col gap-1">
      <Button onClick={() => scan.mutate()} disabled={scan.isPending}>
        {scan.isPending ? 'Scanning…' : 'Scan QR code on this page'}
      </Button>
      {outcome && (
        <p
          role="status"
          data-testid="scan-result"
          className={`text-center text-[12px] ${outcome.kind === 'sent' ? 'text-pp-text-secondary' : 'text-pp-error'}`}
        >
          {named ? `${named}. ` : ''}
          {SCAN_MESSAGES[outcome.kind]}
        </p>
      )}
    </div>
  );
}

export function PopupView({ api }: { api: PopupApi }) {
  const user = useQuery({ queryKey: ['user'], queryFn: () => api.user(), retry: false, enabled: api.accountEnabled });
  const status = useQuery({ queryKey: ['status'], queryFn: () => api.status() });
  const shortcut = useQuery({ queryKey: ['shortcut'], queryFn: () => api.panelShortcut() });
  return (
    <main className="flex w-[22rem] flex-col gap-4 bg-pp-surface p-4 text-pp-text">
      <header className="flex items-center gap-2">
        <img src="/icon/32.png" alt="" width={20} height={20} />
        <h1 className="text-[15px] font-semibold">PasswordPie</h1>
      </header>
      <div className="flex flex-col gap-1">
        <Button kind="primary" big onClick={() => void api.openPanel()}>
          Open PasswordPie
        </Button>
        <p className="text-center text-[12px] text-pp-text-tertiary">
          {shortcut.data ? `or press ${shortcut.data} in the browser` : 'or press the PasswordPie shortcut, ⌘\\ by default'}
        </p>
      </div>
      <ScanQr api={api} />
      {status.data?.codeSkippedOn && (
        <p className="rounded-md bg-pp-field px-3 py-2 text-[12px] text-pp-text-secondary" role="status">
          The two-step code on {status.data.codeSkippedOn} was not filled: it needs Premium.
        </p>
      )}
      {api.accountEnabled && (
        <section className="border-t border-pp-border pt-3" aria-label="Account">
          {user.isPending ? (
            <p className="text-[13px] text-pp-text-tertiary">Checking your account…</p>
          ) : user.data ? (
            <Account api={api} user={user.data} />
          ) : user.isError ? (
            <p className="text-[13px] text-pp-text-secondary">Could not reach passwordpie.com. Try again later.</p>
          ) : (
            <SignIn api={api} />
          )}
        </section>
      )}
    </main>
  );
}

export function Popup({ api, client }: { api: PopupApi; client?: QueryClient }) {
  const [queryClient] = useState(() => client ?? new QueryClient({ defaultOptions: { queries: { retry: 1, staleTime: 0 } } }));
  return (
    <QueryClientProvider client={queryClient}>
      <PopupView api={api} />
    </QueryClientProvider>
  );
}
