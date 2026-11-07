import { act, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { afterEach, expect, it } from 'vitest';
import { PageFiller } from '../src/lib/page-filler';

declare global {
  var IS_REACT_ACT_ENVIRONMENT: boolean;
}
globalThis.IS_REACT_ACT_ENVIRONMENT = true;

let seen: { user: string; pass: string } = { user: '', pass: '' };

function Login() {
  const [user, setUser] = useState('');
  const [pass, setPass] = useState('');
  seen = { user, pass };
  return (
    <form>
      <input type="email" value={user} onChange={(e) => setUser(e.target.value)} />
      <input type="password" value={pass} onChange={(e) => setPass(e.target.value)} />
    </form>
  );
}

afterEach(() => {
  document.body.innerHTML = '';
});

it('fills React controlled inputs so React state holds the values', async () => {
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  await act(async () => root.render(<Login />));

  const filler = new PageFiller({ document, origin: location.origin, frameAllowed: () => true, notifyPasswordFilled: () => {} });
  let result: unknown;
  await act(async () => {
    result = filler.handle({ type: 'fill', origin: location.origin, username: 'octocat@example.com', password: 's3cret' });
  });
  filler.stop();

  expect(result).toEqual({ username: true, password: true });
  expect(seen).toEqual({ user: 'octocat@example.com', pass: 's3cret' });
  const [u, p] = Array.from(container.querySelectorAll('input'));
  expect(u?.value).toBe('octocat@example.com');
  expect(p?.value).toBe('s3cret');
  await act(async () => root.unmount());
});
