import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const FIXTURES = resolve(import.meta.dirname, 'fixtures');

export function loadFixture(name: string): void {
  document.body.innerHTML = readFileSync(resolve(FIXTURES, name), 'utf8');
}

export function input(id: string, root: Document | ShadowRoot = document): HTMLInputElement {
  const el = root.getElementById(id);
  if (!(el instanceof HTMLInputElement)) throw new Error(`no input #${id}`);
  return el;
}
