import { showsSignIn } from './fields';
import type { SignInAsk } from './protocol';

export interface SignInEnv {
  document: Document;
  /** `location.origin` of this frame. */
  origin: string;
  /** True in the top frame, or in a frame that is same-origin with the top frame. */
  frameAllowed: () => boolean;
}

/**
 * A frame's answer to the background's `sign-in` ask: whether it shows a sign-in form. Only a frame a fill could reach
 * says yes: one of the asked origin that is the top frame or same-origin with it. The answer is the boolean alone.
 */
export function signInAnswer(ask: SignInAsk, env: SignInEnv): boolean {
  if (env.origin !== ask.origin || !env.frameAllowed()) return false;
  return showsSignIn(env.document);
}
